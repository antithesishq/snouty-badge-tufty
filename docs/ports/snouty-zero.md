# snouty-zero on the Tufty

Snouty Zero is an F-Zero-style Mode 7 hover racer on a planet-sized AI
datacenter: nine tracks in three leagues (Edge, Spine, Core), four named
rivals plus traffic, Overclock paid for in thermal, and the Antithesis
mechanic: hold to run the whole race backwards on a snapshot bar, and a
crash rewinds by itself. 60 fps. The sources are in
`snouty-badge/carts/snouty-zero` (M5). Since its M5 the cart is
**XIP-only** (code and read-only data execute from the 256 KB cart flash
window; the active track's map and art are unpacked into RAM at race
start), so it is the arcade's one XIP cart. The cart runs as built for
SYCL, plus one Tufty-only change behind `-Dbadge=tufty` (the title takes A,
the cards say `PRESS C`; section 3). The XIP mechanics (packing, CRC check,
VTOR launch) are in [snouty-genesis.md](snouty-genesis.md) section 3, and
the map primitives are in [README.md](README.md) and `src/controls_map.zig`.

## 1. Build and flash

```sh
zig build                          # snouty-tufty-arcade.uf2: zero is the last menu entry
zig build -Dcart=snouty-zero       # the cart alone, scale fit
# -> zig-out/firmware/snouty-tufty-arcade.uf2              (OS + 7 RAM carts + zero at 0x101C0000)
#    zig-out/firmware/snouty-tufty-snouty-zero.uf2         (OS + zero at 0x101C0000)
#    zig-out/firmware/snouty-tufty-snouty-zero-os.elf      (the Tufty OS alone)
#    zig-out/firmware/cart/snouty-zero-xip.{elf,bin}       (the cart; bench the ELF)
#    zig-out/firmware/*.flash.txt                          (where everything landed)
```

The row is `.{ .name = "snouty-zero", .binary = "snouty-zero", .xip = true }`
in build.zig's `carts`, so the menu title is the default "SNOUTY ZERO" (the
name the cart gives itself), and the blurb is `C GO  UP BOOST  A+B REWIND`.
The monorepo builds it with `-Dcart-mode=xip -Dbadge=tufty` and the cart's
defaults (`-Dzero_floor=row`, no debug overlay, sound off). The cart needs
no drive or romfs data: every track, tileset and sprite is embedded in its
image.

Flash as in [../DEPLOY.md](../DEPLOY.md). In the arcade a HOME short press
returns to the menu; in the single-cart UF2 it restarts the cart (splash,
title). HOME held 1 s reboots into BOOTSEL. Everything is below 0x10200000,
so the badge's ROMFS and FAT survive.

## 2. Flash map

From the build's `.flash.txt` files and an independent block scan
(2026-10-02):

| Range | Arcade UF2 (3,402 blocks) | Single-cart UF2 (835 blocks) |
|---|---|---|
| 0x10000000.. | Tufty OS, menu, the seven RAM cart images to 0x100A2880; blocks end at 0x100A4500 (657 KB) | Tufty OS alone, to 0x10003E00 (15.5 KB) |
| ..0x101C0000 | not written | not written |
| 0x101C0000..0x101F0454 | snouty-zero, 197,716 bytes, byte-identical (vector table, `.text`, `.ARM.ex*`, `.data`'s flash copy); 773 blocks to 0x101F0500 | the same |
| 0x101F0500..0x10200000 | not written (59 KB of the window spare) | the same |
| 0x10200000.. | never touched | never touched |

Both UF2s: one RP2350_ARM_S block sequence, no `0x10ffff00` block, no
block at or above 0x10200000, every RAM cart below 0x101C0000. flash_check
requires the image at exactly 0x101C0000, byte for byte. The window's
vector table reads SP 0x20080000 and reset 0x101CB4F1 (Thumb, inside the
window), which is what the OS checks at boot before its CRC32 of the window
(~0.2 MB). A failed check dims the row in the arcade ("BAD CART IMAGE") and
shows the cyan error screen in the single-cart build.

## 3. Controls the cart reads

From `cart/src/main.zig`, `sim.zig` and `input.zig` (edges once per 60 Hz
update):

| Input | Race | Menus and screens |
|---|---|---|
| Left / Right (held) | steer (rate falls with speed) | machine row: cycle the machine |
| A (held) | accelerate | confirm (edge); results, standings: continue |
| Down (held) | brake; with a steer, the tight turn (more yaw, less grip) | cursor down |
| Up (edge) | Overclock: 90 ticks of boost for 250 of the 1000 thermal | cursor up |
| B (held) | rewind while the snapshot bar lasts | back (edge) |
| Start (edge) | pause (Resume, Restart, Quit, Sound); after the finish: results | title and splash: the only way on (SYCL); menus: confirm |

The cart never reads Select (RUNNING.md's minimap toggle is not wired:
nothing sets `hud.minimap_large`) or click. Any edge leaves the attract
demo.

**Tufty strings (submodule `tufty` ddd04fc).** The title took only Start
and said `PRESS START`, which on the Tufty is a two-button chord. With
`-Dbadge=tufty` the title also takes A (the Tufty's C), and the title,
results and Grand Prix standings cards say `PRESS C` (the results and
standings already took A). Nothing else on screen names a button. The SYCL
build is byte-identical (docs/CARTS.md).

## 4. Tufty map (`controls_map.snouty_zero`)

| Tufty | Cart sees | Race | Menus |
|---|---|---|---|
| **A** | left, at once | steer left | machine row: previous |
| **B** | right, at once | steer right | machine row: next |
| **C**, first press | a, **latched on** | the throttle, from then on | title: start; confirm |
| **C**, any later press | a drops for 2 presents, then on again | (a 2-tick lift) | a fresh A press: confirm |
| **UP** | up, after 60 ms | Overclock | cursor up |
| **DOWN** | down, after 60 ms | brake / tight turn | cursor down |
| **A+B** (held) | b | rewind | back |
| **UP+DOWN** | start | pause; again: resume (cursor on RESUME) | confirm |
| HOME short / held 1 s | (OS) | arcade menu, or restart / BOOTSEL | |

`chord_ms` is 0 for the map, and the UP and DOWN bindings carry their own
`chord_ms = 60` (a new per-binding override in `src/controls_map.zig`).

Why this map:

* **The throttle is latched**, as snouty-bugs latches its autofire. A racer
  holds accelerate almost all the time, and the right thumb can rest on C
  or on UP/DOWN, not both. With the throttle latched the left thumb steers
  on A/B, and the right thumb is free for UP (Overclock) and DOWN (brake,
  tight turn) at any moment. Braking while the throttle is on still slows
  the machine (brake 3% of the speed a tick against 0.04 px/tick^2 of
  thrust), and the tight turn is DOWN + steer under throttle, as in F-Zero.
* **Every later C re-presses A** (`retrigger`), so the same button confirms
  in the menus and continues from the results. There is no throttle-off:
  the cart never needs one (DOWN brakes, the finished player coasts by the
  cart's rule), and a toggle would leave C sending no press edge half the
  time, which the menus need. The lift on a re-press is 2 presents (33 ms
  of no thrust). A HOME restart (fresh mapper) clears the latch; nothing is
  latched at boot, and the arcade hides the launching C until it is
  released.
* **A+B = rewind**, the left thumb flat across both, as in snouty-bugs and
  snoutenstein: left and right cancel, and while rewinding the cart ignores
  every other input. chord_ms 0 on A/B: the first member leaks at most 2
  presents of steer, which the rewind takes back at once. Steering itself
  is never delayed.
* **UP+DOWN = Start**, held while the chord is (one edge: pause, the next
  resumes). Here a leak would cost: an UP first would fire an Overclock
  (a quarter of the thermal bar) just before the pause, and in the pause
  menu a leaked UP or DOWN would move the cursor before Start confirms,
  turning "resume" into RESTART or QUIT. So UP and DOWN alone wait 60 ms
  (the chord forms inside that and nothing leaks), while A/B stay instant.
  A tap of UP shorter than 60 ms still reaches the cart once, on release.
* **Select and click are never sent**, so the SYCL OS's Start+Select exit
  can never form either.

Alternatives (not built; each is a map edit):

* **C held = throttle, no latch**: the right thumb would have to leave the
  gas to Overclock or brake. Worse for a racer.
* **Map `chord_ms = 60` for all**: also delays steering by 60 ms. The
  per-binding override exists to avoid that.
* **C tap/hold** for pause: holding C feels like holding the gas, so a hold
  would pause by accident.
* **A+B tap = pause, hold = rewind**: a thumb rolling from A to B in a hard
  steer would pause the race.

Host tests (`zig build test`, 7 for this map, "zero:"): `for_cart` picks
the map; A/B steer on the first loop, UP/DOWN from 60 ms; a C press latches
A for 600 presents; nothing is latched at boot and steering alone never
accelerates; a 5 ms C tap latches it, and steer + DOWN and steer + UP
reach the cart with the throttle on; every later C (held, sub-present,
consecutive) is a fresh A edge and A is back on after each; a fresh mapper
clears it; UP+DOWN formed 40 ms apart (UP first) and 50 ms apart (DOWN
first) gives one Start edge each and no up/down at all, even released one
at a time; a 20 ms UP tap gives one Overclock edge; A+B gives b on at
least 58 of 60 updates a second with at most 2 presents of steer leak, the
member still held stays masked; over all 32 button sets held for 1.2 s,
never Select or click, Start only from UP+DOWN, and no up/down while UP+DOWN
are both held. The tests run a 60 Hz cart model over a 1 ms OS loop.

## 5. Screen: fit

* The HUD's lap, clock and rank are at y 1..8 and the speed, thermal and
  snapshot bars and the minimap reach y 126. Crop drops rows 0..3 and
  124..127: the top three rows of every HUD glyph and the minimap's bottom
  edge. So the row keeps the default, fit.
* The floor is a per-row affine texture and the horizon a 32-row strip;
  fit's 16 single rows are hard to see in motion. The 8x8 text gets one
  short row per glyph, as in every fit cart.
* `-Dscale=crop` and `-Dscale=native` still work for `-Dcart=snouty-zero`.

What you should see: the splash (Snouty's head, "SNOUTY ZERO /
ECUMENOPOLIS GRAND PRIX", 2 s), the title over Cold Aisle turning, blinking
`PRESS C`. C: the main menu (QUICK RACE, GRAND PRIX, MACHINE, SOUND: OFF);
UP/DOWN move, C chooses, A+B goes back. A race starts with PROVISIONING,
3, 2, 1, DEPLOY, and the throttle is already on from the menu presses. 10 s
idle on the title starts the attract demo (the autopilot races and
rewinds); any button returns. Sound is off and the Tufty has no buzzer.

## 6. RAM and frame pacing

The XIP ELF lays out exactly as on SYCL (`cart_xip.ld`):

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (zeroed at launch) |
| 0x20035100..0x20035374 | `.data`, 628 bytes (copied from the window by the cart's reset handler) |
| 0x20035378..0x20048E20 | `.bss`, 80,552 bytes (the unpacked 16 KB map, the league tiles and horizon copied in at race start, history, world) |
| 0x20048E20..0x20078000 | free (188 KB) |
| 0x20078000..0x20080000 | 32 KB stack, initial SP 0x20080000 |

The cart calls `set_vsync_enabled(1000/60)` and runs `no_copy_full_frame`;
the OS paces presents on TIMER0 at 16,667 us. A present is ~7.4 ms on
core 0, inside the period.

## 7. Bench

badge-bench (calibrated, `calibrate/calibration.toml`, busy ms) on
`zig-out/firmware/cart/snouty-zero-xip.elf` from this build (the
`-Dbadge=tufty` cart, sha256 a8a79bd67962), modelled at 150 MHz with
zero-wait flash (`--flash-cycles 0`, its XIP default). Budget 16.7 ms
(60 fps). The Tufty estimate is x 0.6 for 250 MHz, **if XIP stalls cost the
same number of cycles** (below).

```sh
cd snouty-badge
badge-bench/bench.sh ../zig-out/firmware/cart/snouty-zero-xip.elf --config badge-bench/carts/snouty-zero.toml \
  --script ../tools/bench/zero_tufty.json --frames 2400 --every 100 --symbols
```

`tools/bench/zero_tufty.json` is what the cart sees through this map: a
Tufty button timeline run through `controls_map.snouty_zero` (a scratch host
program calling `Mapper.update` every 1 ms, one cart update per 1/60 s),
written out as the Controls per update. The timeline: C at 125, 145, 165,
185 (title, QUICK RACE, EDGE, COLD AISLE; the throttle latched from the
first, the re-press gaps visible at 145, 165, 185), B 430..470, an UP tap
at 500 (Overclock reaches the cart at 504), A+B 560..620 (rewind),
UP+DOWN 700..710 and 760..770 (pause, resume), B+DOWN 800..880 (tight
turn), A 900..960, B 1000..1040; the blind drive crashes until JOB KILLED
and the results (by frame 950); C at 1500..1560 back through the menus into a
second Cold Aisle race (the grid start again), B, A+DOWN and A+B (rewind)
2100..2160. Every screen was checked in the bench's PNG frames.

| Run | mean ms @150 | p95 | worst ms @150 | est. @250 mean / worst |
|---|---|---|---|---|
| Tufty map, `zero_tufty.json`, 2400 frames (two races, rewind, pause, results, menus) | 2.36 | 3.29 | **4.52** (frame 2104, a rewind frame) | 1.4 / **2.7** |
| cart's own `m3_bench.json`, 1700 frames (Start-driven; the Tufty title still takes Start) | 2.05 | 3.25 | 4.74 (frame 561, the grid start under a steer) | 1.2 / 2.8 |

0 frames over budget; the worst frame uses 27-28% of 16.7 ms at 150 MHz
and ~17% at 250. The `m3_bench` run reproduces the cart's own M5 figures
(2.05 / 4.74), so the Tufty build of the cart is the monorepo's. Hot:
`render.draw` (the floor) 70%, `main.draw_race` 10%, `font.plot_glyph`
8%, `api.rect` 7%.

**The XIP assumption.** badge-bench charges instruction fetches from the
window at SRAM cost and never charges data loads from it. On the badge the
cart's 196.5 KB of code and read-only data go through the RP2350's 16 KB
XIP cache, shared with core 0's OS loop (which also runs from flash). The
cart keeps the heaviest data out of it: the floor's tiles, palette and
horizon are copied to RAM and the map unpacked to RAM at race start, so the
per-pixel loops read only RAM. Sprite sheets, the font and the code still
come through the cache. Flash timing is the genesis analysis
([snouty-genesis.md](snouty-genesis.md) section 5): the bootrom's QMI
setting is CLKDIV 3 on both badges, so a miss costs the same number of
system cycles at 250 MHz (83 MHz SPI) as at 150 (50 MHz), and the x 0.6
holds for the stalls too. The headroom is large: the worst frame is
~719 K instructions, and 60 fps at 250 MHz would only be lost at an average
stall of ~4.9 cycles per instruction (at 150 MHz on SYCL: ~2.5). Unmeasured
on hardware, like every XIP number.

## 8. Risks and unknowns

* **XIP on the Tufty is unproven** (shared with snouty-genesis): the read
  timing margin at 83 MHz SPI (RXDELAY 2 = 4 ns), and the cache hit rate.
  The boot CRC check reads the whole window, so a bad read shows as a dimmed
  row / cyan screen rather than a crash. Fallback: a 150 MHz cart host
  (`sys_mhz` in build.zig `add_os`) puts SPI back at the SYCL badge's
  50 MHz; this cart has 3.5x headroom at 150 MHz.
* **One window.** The arcade can hold no other XIP cart while snouty-zero
  is in it. snouty-genesis stays single-cart anyway (its drive overlaps the
  RAM carts).
* **The throttle cannot be released** short of HOME. If play testing wants
  a coast, the map can add an unlatch (e.g. DOWN held long) without a cart
  change.
* **UP/DOWN are 60 ms late**, Overclock and braking included, and so is
  menu navigation. Steering is not delayed.
* **VTOR** points at the cart's vector table while it runs, as on SYCL: a
  fault on core 1 looks like a hang (HOME still works, on core 0).
* **The cart's docs list Select = minimap size**, but the code never reads
  it, so the Tufty sends none. If upstream wires it, UP+DOWN tap/hold could
  carry it (snoutenstein's pattern).
* The cart does not call `cart.rand()`; races are deterministic by design
  (rewind), and the attract demo cycles tracks.
* Untested on hardware, like every Tufty build before its gate.
