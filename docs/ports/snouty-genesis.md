# snouty-genesis on the Tufty

Snouty Genesis is the monorepo's Sega Genesis / Mega Drive emulator: a
68000 + Z80 + VDP core, 30 presents a second with two Genesis frames per
update, a 500 ms Select hold for the emulator menu (scrub / rewind, button
layout, scale, Smooth H40, sound, reset, ROM picker, About). The sources
are in `snouty-badge/carts/snouty-genesis` (`tufty` branch, c77fd61). It is
the first **XIP cart** on the Tufty: its code runs from flash, so it cannot
be a RAM image like the other ports. The cart is **unmodified** apart from
its `-Dbadge=tufty` strings and debug-overlay default (section 4); the Tufty
OS learned to run XIP carts, and the UF2 carries the ROM on a FAT12 drive
image, the same way the SYCL badge's USB drive holds it.

It ships as its own UF2, `snouty-tufty-genesis.uf2`, not in the arcade.

## 1. Build and flash

```sh
zig build -Dcart=snouty-genesis -Dgenesis_rom=/home/exedev/roms/genesis/sonic1.bin
# -> zig-out/firmware/snouty-tufty-genesis.uf2         flash this (OS + drive + cart)
#    zig-out/firmware/snouty-tufty-genesis.flash.txt   where everything landed
#    zig-out/firmware/snouty-tufty-genesis-os.elf      the Tufty OS alone (no cart in it)
#    zig-out/firmware/cart/snouty-genesis-xip.{elf,bin}    the cart (bench it with the ELF)
#    zig-out/firmware/cart/snouty-genesis-drive.{img,txt}  the FAT12 drive and its report
zig build -Dcart=snouty-genesis      # no ROM option: the open Miniplanets (zlib, shipped with the cart)
```

* `-Dgenesis_rom` takes an absolute path or one relative to this repository.
  There is no `~` expansion and no existence probe (this Zig caches the
  configure graph by build files + options only); a missing file fails the
  build when the drive image is written.
* **Never commit a commercial ROM.** The ROM is read from where it lies.
  Copies end up only in `zig-out/` and `.zig-cache/` (both ignored), and
  inside the UF2 itself, so do not share a UF2 built with Sonic.
* The drive file is the option's basename in 8.3 form (`sonic1.bin` ->
  `SONIC1.BIN`; an extension the cart does not scan becomes `.BIN`).
* `-Dscale=crop` builds the crop variant (section 4).

Flash as in [../DEPLOY.md](../DEPLOY.md). HOME short press restarts the
emulator (fresh RAM, game lost); HOME held 1 s reboots into BOOTSEL.
Restoring the stock firmware is unchanged: everything here is below
0x10200000, the stock firmware slot, and the badge's ROMFS and FAT survive.

## 2. Flash map

From `snouty-tufty-genesis.flash.txt` (Sonic build, 2026-10-02):

| Range | What | How it gets there |
|---|---|---|
| 0x10000000..0x10003E00 | Tufty OS (15.5 KB), no cart image in it | its own ELF -> UF2 |
| 0x10080000..0x10102600 | FAT12 drive image, 534,016 bytes: boot sector, 2 FATs, root dir, then the ROM | tools/drive_image.zig, packed by tools/uf2_pack.zig |
| 0x10082600..0x10102600 | inside it: `SONIC1.BIN`, 524,288 bytes, clusters 2..1025, contiguous | |
| 0x10102600..0x101C0000 | not written (old firmware bytes; the volume marks them free) | |
| 0x101C0000..0x101F92E4 | the XIP cart, 234,212 bytes of the 256 KB window (vector table, .text, .ARM.ex*, .data's flash copy) | objcopy of `snouty-genesis-xip.elf`, packed |
| 0x10200000.. | the badge's ROMFS and FAT drive | never touched |

3,063 UF2 blocks, all RP2350_ARM_S, 256-byte payloads, numbered as one
sequence, no 0x10ffff00 block. flash_check requires the drive at exactly
0x10080000 and the cart at exactly 0x101C0000, byte for byte, finds the ROM
inside the drive (0x10082600), and fails the build if anything outside the
window reaches 0x101C0000 or anything reaches 0x10200000.

These addresses are the SYCL badge's, from source: `sycl-badge/src/os/linker.ld`
(romfs 0x10080000, 1280 KB; cart_xip 0x101C0000, 256 KB), `src/cart/cart_xip.ld`
(FLASH 0x101C0000, RAM 0x20035100 + 0x4AF00, `__stack_top__` 0x20080000)
and `snouty-badge/lib/romfs.zig` (`base_addr` 0x10080000). The drive image
is the volume the SYCL OS formats (storage.zig `formatVolume`): 1280 KB,
512-byte sectors, 2 FATs of 8 sectors, 32 root entries, label SYCLBADGE,
truncated after the ROM. It is byte-identical to
`make_romfs.py OUT sonic1.bin=SONIC1.BIN --truncate`, and a host test reads
it back through the cart's own `romfs.zig` (contiguous, byte-identical).

## 3. Design

**XIP carts in the Tufty OS** (cart_host.zig, os/cart_image.zig). A cart
table row with `.xip = true` gets an empty slot in the OS; the UF2 puts its
image at its link address, so nothing writes flash at run time. At boot the
OS:

1. reads the window's vector table and checks it as the SYCL OS's
   `executeCart` does: SP 8-aligned and inside cart RAM (0x20080000 here),
   reset handler odd and inside 0x101C0000..0x10200000;
2. CRC32s the window image and the drive against the values the build
   recorded (`xip_meta`, tools/xip_meta.zig), about 750 KB, an estimated
   50 ms once at power-on.

A launch stops core 1, zeroes 0x20020000..0x20080000 (IPC block included),
copies nothing, and starts core 1 with the same NVIC/SysTick/fault clean-up
as RAM carts, then VTOR = 0x101C0000, MSP = vector[0], `bx` vector[1]. The
cart's reset handler (snouty-badge `build/xip/entry.zig`) turns on the FPU
and the cycle counter, copies `.data` (168 bytes) from flash and zeroes
`.bss` (166 KB), then runs the SDK's normal `_start` loop: the SYNC_TIME
handshake, `start()`, update/present. From there the OS serves it exactly
like a RAM cart. HOME stops it the same way (core 1 forced off, DMA
aborted, FIFO drained).

Reusable: the arcade can hold one XIP row beside its RAM carts (one window).
That path builds and packs (checked with a temporary genesis row: OS + six
RAM carts below 0x10092100, the XIP image at 0x101C0000, all checks pass),
and the row dims if its window fails the checks. See ARCADE.md, "One XIP
cart in the arcade". snouty-genesis itself stays out (`.arcade = false`):
its drive at 0x10080000 overlaps the arcade's RAM carts (they already reach
0x10092100). Putting it in the arcade would need the drive elsewhere, which
means a `romfs.base_addr` build option on the `tufty` branch (lib/romfs.zig
is shared with Boy, Gear and Lynx).

**ROM delivery: a FAT12 drive in the UF2.** The cart's default build
(`-Dmd-rom-source=drive`) scans the SYCL drive at 0x10080000 for
`.gen/.md/.bin` files and reads the ROM in place by pointer. Writing that
drive into the UF2 needs zero cart change, keeps the cart's embedded
fallback the 16 KB test ROM, and takes the cart's fast path (one file,
contiguous: no picker, a single base pointer). The alternative,
`-Dmd-rom=` (embed), cannot work for a 512 KB ROM: the embedded ROM lives
in the 256 KB XIP window, and the cart's own docs say that link fails. The
drive holds up to 1,270 KB (2,541 clusters), so 1 MB ROMs fit too.

**Controls** (`controls_map.snouty_genesis`). The cart turns SYCL controls
into a Genesis pad (default layout `B=B A=C S=A`): badge A = Genesis C,
badge B = Genesis B, Start = Start, a Select tap = Genesis A, Select held
500 ms = the emulator menu.

| Tufty | Cart sees | Genesis (Sonic) | In the cart menu |
|---|---|---|---|
| A | left | left | scrub back 0.5 s / previous setting |
| B | right | right | scrub forward / next setting |
| C | a | C: jump | choose / toggle |
| UP | up | up: look up | cursor up |
| DOWN | down | down: crouch, roll while running | cursor down |
| A+B | b | B: jump (the left-thumb jump) | back / resume |
| UP+DOWN tap (< 250 ms) | start (pulse) | Start: pause, start from the title | (ignored) |
| UP+DOWN held 300 ms | select, held until release | the menu opens 500 ms later (0.8 s in all); released before that = a Select tap = Genesis A | a Select tap also resumes |
| HOME short / held 1 s | (OS) | restart the emulator / BOOTSEL | |

* Down + jump with one right thumb is the hard case (crouch-jump; Sonic 2's
  spin dash). A+B gives jump to the left thumb, so DOWN stays on the right:
  hold DOWN, press A+B. Sonic 1 has no spin dash; roll is a direction +
  DOWN, which the split pad already allows.
* chord_ms 0 (a platformer: no delay on left/right). The first button of a
  chord leaks for 2 presents: a one-frame step in play, harmless. In the
  cart menu, on a scrub row, an A-first A+B scrubs back 0.5 s before it
  resumes; press B a hair first, or use the UP+DOWN release.
* All Genesis buttons stay reachable: the menu's `Btns` row re-assigns
  badge A/B/the tap (e.g. `B=B A=A S=C`).
* Host tests (`zig build test`, "genesis:"): one control per button; run +
  jump and direction + DOWN together; A+B masks left/right and works with
  DOWN held; UP+DOWN tap gives one Start and no Select; UP+DOWN held gives
  Select through the cart's 15-update hold and no Start; click is never
  sent, Start/Select only from UP+DOWN, over all 32 button sets.

**Scale: fit** (128 -> 240 rows). The cart already squeezes 224 Genesis
lines into 128 rows (row r shows line r*7/4), and draws its menu footer
("B: back to game", y 119), the scrub bar and the play hint strip (rows
118..127) on its bottom rows; crop (rows 4..123) would cut them. Fit
doubles 7 rows in 8, so 128 distinct Genesis lines fill 240 panel lines:
close to the Genesis's own 224, but only 128 of them. `-Dscale=crop` is the
pixel-exact alternative if the UI loss is acceptable (Sonic's HUD starts at
row ~5 and survives).

**Native 320x224 (a stretch, not built).** The panel is 320x240 and a
Genesis H40 frame is 320x224: a 1:1 picture with 8 black lines top and
bottom. What it would take:
* cart: a `-Dbadge=tufty` render path that emits all 224 lines at 320
  pixels (the VDP renders H40 at 320 already when Smooth H40 is on; the
  line table would become identity), about 1.75x the renderer's share
  (render_line + plane + on_line, ~27% of an update now);
* ABI: a 320x224 RGB565 frame is 140 KB, which does not fit cart RAM next
  to the 137 KB console. The cart would stream lines instead: a small ring
  of 320-px lines in the IPC block that core 0 DMAs straight into a
  320x224 panel window (new FIFO messages, OS-side pacing per line batch);
* PSRAM (8 MB on QMI CS1) could hold a full frame, but it shares the QMI
  with flash, so it would compete with the XIP fetches this cart lives on.

## 4. What to expect

1. Power-on: ~0.3 s panel bring-up, the boot CRC check (~50 ms, black).
   A **cyan** screen means the cart window is empty or not this build's (the
   UF2 did not fully land); **orange**, the drive is not this build's.
2. The cart's 1.2 s splash (Iris mark, "SNOUTY GENESIS", "Hold UP+DOWN:
   menu" in the Tufty build), any button skips it.
3. Sonic: the SEGA screen, then the title (about 13 s after power-on in the
   bench). **UP+DOWN tap = Start.** Green Hill Zone act 1 follows.
4. The debug overlay is **off** at boot in the Tufty build (on the SYCL
   badge it is on; `-Dbadge=tufty` flips the default, c77fd61). Turn it
   on with the menu's `Debug overlay` row: top left `avg`/`max` update
   microseconds, then presents and emulated frames per second. **These are
   the real 250 MHz numbers: write them down.** The bottom lines read
   `ROM: drive contiguous SONIC1.BIN 512 KB crc ...` (the CRC fills in
   over the first seconds). The same row hides it again.
5. Sound is off (no audio on the Tufty); tones are accepted and dropped.

The on-screen names follow the Tufty map above (snouty-badge `tufty`
c77fd61, `-Dbadge=tufty`; docs/CARTS.md has the full table and
[tufty-labels-genesis.png](tufty-labels-genesis.png) the before/after):

| Screen | SYCL | Tufty |
|---|---|---|
| splash, first 3 s of play | `Hold Select: menu` | `Hold UP+DOWN: menu` |
| menu, Resume row | `Left/Right: rewind` | `A/B: rewind` |
| menu footer / About | `B: back to game` / `B: back` | `A+B: back to game` / `A+B: back` |
| menu, Buttons row | `Btns B=B A=C S=A` | `Btns AB=B C=C UD=A` (UD = the short UP+DOWN hold, the Select tap) |
| ROM picker | `A: play`, `B: test ROM` | `C: play`, `A+B: test` |
| no-ROM help | `A: run test ROM`, "Copy ... to the SYCLBADGE drive, eject, restart." | `C: run test ROM`, "Build with -Dgenesis_rom=FILE (.gen, .md or .bin), flash the UF2." |

The shared lib/hint.zig keeps the SYCL strings for Boy, Gear and Lynx; the
Tufty set is `hint.tufty_genesis`, picked in frontend/input.zig (`hints`).

## 5. Bench

badge-bench (calibrated, `calibrate/calibration.toml`) on
`zig-out/firmware/cart/snouty-genesis-xip.elf` (sha256 726b68fc3793),
150 MHz modelled, the ROM read from the drive image the UF2 carries
(`--romfs`), budget 33.3 ms (30 Hz). The Tufty estimate is x 0.6, **if XIP
stalls cost the same number of cycles** (below).

```sh
cd snouty-badge
badge-bench/bench.sh ../zig-out/firmware/cart/snouty-genesis-xip.elf --no-config --budget-ms 33.3 \
  --romfs ../zig-out/firmware/cart/snouty-genesis-drive.img \
  --script ../tools/bench/genesis_sonic1.json --frames 900 --symbols
```

| Run | mean ms @150 | p95 | worst ms @150 | over 33.3 @150 | est. @250 mean / worst |
|---|---|---|---|---|---|
| Sonic 1, 900 updates (splash, SEGA, title, Start, GHZ1 running right + jumps, a death and the act restart) | 23.33 | 32.71 | 35.40 (update 521, the act start behind its title card) | 24 of 900 | 14.0 / 21.2 |
| Sonic 1, GHZ1 play only (updates 560..760) | 23.35 | 26.91 | 33.45 | 1 | 14.0 / 20.1 |
| Miniplanets (drive), the cart's `m2_mini300` script, 336 updates | 20.78 | 27.11 | 29.14 | 0 | 12.5 / 17.5 |

* The Miniplanets run reproduces the cart's own M4 figures (20.74 / 29.07),
  so the Tufty build of the cart is the monorepo's.
* Sonic is heavier than Miniplanets (3.46 M instructions per update vs 3.08 M):
  over the SYCL budget on 24 updates at 150 MHz (title-card and
  transition frames), all well inside it at 250 MHz (worst ~64%).
* Hot: `step_frame` (68000 inlined) 38%, `run_z80` 24%, VDP `plane` 11%,
  `render_line` 10.5%, `video.on_line` 5%.
* The script is `tools/bench/genesis_sonic1.json` (bench ticks are updates:
  START 150 and 420, RIGHT 500..880, A = Genesis C every 60 updates).

**The XIP assumption.** badge-bench models flash as zero-wait. The cart's
code (229 KB) runs through the 16 KB XIP cache, shared with core 0's OS loop
and with the ROM reads from the drive. The cart's RUNNING.md measured the
sensitivity: every 0.1 cycle of average fetch stall per instruction costs
~1.7 ms per update at 150 MHz; ROM data reads hardly matter (4 wait cycles
on every load: +0.6 ms).

Flash timing on the Tufty: neither the Tufty OS nor microzig touches the QMI,
so XIP runs as the RP2350 bootrom left it after flash boot. An RP2350 report
of that state (pico-sdk issue #1903) reads `M0_TIMING` 0x60007203 (CLKDIV 3,
RXDELAY 2) with quad `EBh` reads, the same on both badges (the SYCL OS does
not touch QMI either). So the SPI clock is clk_sys / 3: 83 MHz at 250 MHz
against 50 MHz on the SYCL badge. Because the divider is the same, a cache
miss costs the same number of **system cycles** on both, and the x 0.6
scaling holds for the stall time too. The headroom grows a lot: at 250 MHz
the worst Sonic update leaves ~12 ms, which absorbs an average stall of
~0.6 cycles per instruction (SYCL: ~0.15, i.e. a ~99.5% hit rate). Unverified
on this badge: read `M0_TIMING` / `M0_RCMD` on hardware.

## 6. RAM

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (zeroed at launch) |
| 0x20035100..0x200351A8 | `.data` (copied from the window by the cart's reset handler) |
| 0x200351A8..0x2005EA04 | `.bss`, 166,004 bytes (the console, ~137 KB, and the frontend) |
| 0x2005EA04..0x20078000 | heap: the scrub arena (~102 KB, about 5 s of rewind in play) |
| 0x20078000..0x20080000 | 32 KB stack (cart_xip.ld), initial SP 0x20080000 |

The OS keeps to 0x20000000..0x20020000, as for every cart.

## 7. Risks for the first hardware run

* **XIP at 83 MHz SPI.** The OS already runs from flash at 250 MHz
  (snouty-run on the badge), with the bootrom's QMI setting. But RXDELAY 2
  is 4 ns at 250 MHz (6.7 ns at 150), the read-sampling margin. The cart is
  the first code that streams hundreds of KB per second through the cache,
  so marginal sampling would show here first: random crashes, a cyan
  screen on some boots (the CRC check reads all of it), garbage tiles.
  Fallback: a 150 MHz cart host (`sys_mhz` in build.zig `add_os`, as the
  `snouty-tufty-hello-150` build does) puts SPI back at the SYCL badge's
  50 MHz, at SYCL speed (24 of 900 Sonic updates over budget).
* **XIP hit rate unknown.** If the overlay's `max` passes ~33 ms, first try
  the menu's `Smooth H40: Off` (about 2.6 ms cheaper per update at 150 MHz),
  then the cart's `render_every = 3` (20 Hz) knob on the `tufty` branch.
* **The UF2 is 1.5 MB / 3,063 blocks, three regions with gaps.** The
  bootrom writes each page where its block says; the boot CRC check shows
  whether all of it landed (cyan / orange).
* **VTOR** points at the cart's 2-entry vector table while it runs, as on
  the SYCL OS: a fault on core 1 then jumps through cart `.text`, so a cart
  crash looks like a hang (HOME still works; it runs on core 0).
* **HOME short press restarts the emulator** and loses the game (there is
  no save). Hold HOME only for BOOTSEL.
* **The menu takes ~0.8 s of UP+DOWN** (300 ms to Select, then the cart's
  500 ms hold). The hint says "Hold UP+DOWN: menu"; letting go between
  0.3 and 0.8 s sends Genesis A instead (the `UD` of the Buttons row).
* Untested on hardware, like the other ports before their gate.
