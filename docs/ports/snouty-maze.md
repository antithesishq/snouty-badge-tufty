# snouty-maze on the Tufty

Snouty Maze is a Windows 3D Maze screensaver clone with a software
rasterizer, at 60 fps. An autopilot walks the maze, and the buttons can take
the camera over. The sources are in `snouty-badge/carts/snouty-maze`
(48c0d18). The cart is the unmodified RAM-mode build, embedded in the Tufty
OS exactly as snouty-run is (see [snouty-run.md](snouty-run.md) section 5
for how the OS runs a cart). The map primitives are defined in
[README.md](README.md).

The one difference from the SYCL build is the cart's own existing build
option: the Tufty build asks for a **16x16 maze** (`-Dmaze_size=16`), the
cart's maximum. The SYCL badge stays at the default 12x12. No cart source
changes. At 250 MHz the bigger maze has room to spare (section 7).

## 1. Build and flash

```sh
zig build -Dcart=snouty-maze     # one cart, booted straight away; fit, 16x16
# -> zig-out/firmware/snouty-tufty-snouty-maze.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/cart/snouty-maze.{elf,bin}     (the embedded cart)
zig build -Dcart=snouty-maze -Dscale=crop            # the alternative scale
zig build                        # also snouty-tufty-arcade.uf2: every cart behind the menu
```

The cart is the last row of build.zig's `carts` table, so it is the last
entry of the arcade menu ("SNOUTY MAZE", controls line `A/B TURN  UP/DN STEP
C SKIP`, from the `blurbs` table). The maze size is that row's `maze_size`
field. `cart_bin` passes it to the monorepo as the
`b.dependency("snouty_badge", .{ .cart = ..., .maze_size = 16 })` argument,
which is the monorepo's own `-Dmaze_size` option (clamped there to 4..16;
`carts/snouty-maze/build.zig`). Carts without the field (and without
`reflections_variant`) get the plain `.{ .cart = ... }` dependency. To try
another size, change the 16 in that row (any of 4..16). The ELF carries it
as the initial value of the exported `maze_size` byte in `.data`, which
reads 16 in this build.

Flash as in [../DEPLOY.md](../DEPLOY.md). In the single-cart UF2 a HOME
short press restarts the cart from a fresh RAM image (a new GROW and walk
from the start cell); in the arcade UF2 it returns to the menu
([../ARCADE.md](../ARCADE.md)). HOME held 1 s reboots into BOOTSEL.

UF2 facts (`snouty-badge/tools/uf2_info.py`, the build's `.flash.txt` and a
block scan):

* `snouty-tufty-snouty-maze.uf2`: 336 blocks, family `0xe48bff59`
  (RP2350_ARM_S), targets `0x10000000..0x10015000` (84 KB), contiguous.
  Far below `0x10200000` (and the arcade's `0x101C0000` budget), and there
  is no `0x10ffff00` block. The cart blob (71,456 bytes) sits
  byte-identical in the payload at `0x10002754`.
* `snouty-tufty-arcade.uf2` with the maze added: 2105 blocks,
  `0x10000000..0x10083900` (526 KB, 29.4% of the 1792 KB budget). The maze
  image is at `0x10070D22..0x10082442`, the smallest of the five carts.

## 2. Controls the cart reads

These come from `cart/src/main.zig` `update()` and `autopilot.stick()`. The
edges are from `input.zig`.

| State | Input | Effect |
|---|---|---|
| WALK / TURN | any direction (edge) | Takeover: MANUAL starts. Other states ignore the stick |
| MANUAL | Up/Down (edge, held repeats) | One cell forward/back. A wall blocks it |
| MANUAL | Left/Right (edge) | Pivot 90 degrees |
| MANUAL | 5 s (300 ticks) with no direction held | The autopilot resumes from the current cell |
| WALK, TURN, MANUAL, GROW | A (edge) | Skip to PAUSE (starts the finish sequence, cuts GROW short; ignored in the other states) |
| every state but fly | Start (edge) | Toggle the name strip permanently on/off. It shows during OVERHEAD anyway |
| all autopilot states | Select (edge) | Flips `leds.enabled`. A no-op, because the LEDs are compiled out |
| debug builds only | B+Select (either order) | Toggle fly mode (`-Ddebug_overlay=true`) |

B is read only in the debug fly mode. Click is never read. The cart is a
screensaver, so "gameplay" is optional walking.

## 3. Tufty map (`controls_map.snouty_maze`)

Physical layout: A, B and C sit along the bottom edge under the screen, UP
and DOWN on the right side of the front. The left thumb rocks between A and
B; the right thumb works C or UP/DOWN (never both at once, which this cart
never needs).

| Tufty | Cart sees | Autopilot | MANUAL |
|---|---|---|---|
| **A** | left | take over, pivot left | pivot left |
| **B** | right | take over, pivot right | pivot right |
| **UP** | up | take over, step forward | step forward (held: repeats) |
| **DOWN** | down | take over, step back | step back (held: repeats) |
| **C, tap** (released within 400 ms) | a, pulse on release | skip to the finish sequence (from WALK, TURN or GROW) | skip to the finish sequence |
| **C, hold** (600 ms) | start, until release | toggle the name strip, once per hold | same |
| C held 400..600 ms | nothing | | |
| HOME, short | (OS) | restart the cart (arcade: back to the menu) | same |
| HOME, held 1 s | (OS) | BOOTSEL | same |

Why this map:

* The direction buttons are direct, with no chords, so a step or pivot is
  never delayed or masked and nothing ever leaks a takeover by accident.
  Any chord built from direction buttons (A+B, UP+DOWN) would send a
  pivot or step in its first frame and start MANUAL, unless the map paid a
  `chord_ms` delay on every move.
* Turning on the left thumb and walking on the right is the split d-pad the
  other ports use (README.md), so the carts feel alike.
* C carries both screensaver buttons. Skip is the one a visitor wants; the
  name strip toggle is rare, so it gets the hold. Skip fires on release,
  which is fine for a screensaver. The start bit stays up while C is held,
  so the cart sees one rising edge and toggles once.
* B, Select (the dead LED flag) and click are never sent. The B+Select fly
  chord only exists in `-Ddebug_overlay` builds and is not reachable.

Alternatives (not built; each is one map edit):

* **A = a (skip), B/C = left/right:** frees the hold, but splits the
  pivots across both thumbs and puts skip under the turning thumb. Worse.
* **Swap the axes:** A = up, B = down, UP = left, DOWN = right. Puts walking
  on the left thumb. Worse: UP/DOWN read naturally as forward/back.
* **C = plain `a` (skip on press), no name strip toggle:** if the OS adopts
  HOME tap = start (README.md, "Optional, OS-wide"), C can be direct and the
  hold goes away. Today HOME tap restarts the cart (or leaves for the menu).
* **A+B chord = start** instead of C hold: costs a pivot leak (or a 60 ms
  `chord_ms` on every turn). Not worth it.

Host tests (`zig build test`): each direction button gives exactly its one
control on the first press and drops on release; a C tap gives `a` for 2
presents and never `start`; a 1 s hold gives `start` from 600 ms with one
rising edge and no `a`; a 500 ms press gives nothing; a 3 ms tap of C still
reaches the cart over 2 presents; all 32 button combinations held give
exactly the direct direction bits, never `b`, `select` or `click`.

## 4. Screen: fit (crop is acceptable)

* The bottom 24 rows hold the name strip: the Iris icon at y 104..127 and the
  text at 106..113 and 116..123 plus a 1 px shadow to 124. Crop drops the
  icon's bottom 4 rows and the shadow of line 2. That is visible but minor,
  so fit is the default (`Cart.scale` left at `.fit`).
* Fit artifacts: the fade overlay (`overlay.fade`) uses a 4x4 Bayer pattern.
  With nearest-row duplication some pattern rows are single and some double,
  so the fades band slightly. The textured walls themselves are fine.
* Crop keeps square pixels and an exact 2x, but loses 8 rows of view.
  `-Dscale=crop` is there to compare on the panel.
* The debug overlay at y 0..18 only exists in `-Ddebug_overlay` builds.

What you should see after power-on (~0.3 s panel bring-up): the maze grows
out of the floor (GROW intro), then the autopilot walks the 16x16 maze:
textured walls, floor and ceiling, the Snouty and smiley actors, the logo
and picture walls. At the finish it rises above the walls (OVERHEAD shows
the carved path and the name strip with the coin-flipping Iris mark),
descends, and starts the next maze.

## 5. Frame pacing

The cart calls `set_vsync_enabled(1000/60)` once in `start()` and runs in
`no_copy_full_frame` mode, like demosnout; the Tufty OS paces presents on
TIMER0 at 16,666 us (demosnout.md section 5 has the details). The maze
measures its own render time with `micros_since_boot` (TIMER0 at 1 MHz, the
same clock as the SYCL badge); that only feeds the debug overlay. A present
takes ~7.4 ms on core 0; a render at most ~9.2 ms modelled on core 1 at
250 MHz (section 7), so both fit one 16.67 ms period.

## 6. RAM

The cart ELF lays out exactly as on SYCL:

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (OS zeroes it) |
| 0x20035100 | `.cart_descriptor`, then `.text` (67,700), `.ARM.extab`, `.ARM.exidx`, `.data` (3,264) to 0x20046820 |
| 0x20046820..0x200598e0 | `.bss`, **78,016 bytes** (16 KB of it colour grids) |
| 0x200598e0..0x20080000 | 157,472 bytes free for the stack |
| 0x20080000 | initial MSP |

The maze arrays are sized for `maze.max_size` = 16 at every build size, so
16x16 costs no RAM over 12x12.

## 7. Bench

badge-bench (calibrated, `calibrate/calibration.toml`, busy ms) on
`zig-out/firmware/cart/snouty-maze.elf` from this build (sha256
ae90f779a00d, maze_size 16 in `.data`), modelled at 150 MHz. 12x12 is the
same ELF with `--poke maze_size=12` before `_start`, which is exactly what
the SYCL default build bakes in. The Tufty estimate is x 0.6 for 250 MHz
(core 1 runs from SRAM, so it scales with the clock). Scripts are the
cart's own: `m2_cycle.json` (A at tick 240, 900 frames: walk, skip, the
whole finish sequence, the next maze's GROW and walk), `m3_tour.json` (1000
frames, no input), `m4_takeover.json` (900 frames of MANUAL walking).
`--seed` seeds the faked ROSC bit, so each seed is a different maze
(section 8).

**16x16 (shipped):**

| Run | mean ms @150 | p95 | worst ms @150 | est. @250 mean / worst |
|---|---|---|---|---|
| m2_cycle seed 1 | 8.62 | 11.38 | 12.04 | 5.2 / 7.2 |
| m2_cycle seed 2 | 7.86 | 11.10 | 12.67 | 4.7 / 7.6 |
| m2_cycle seed 3 | 9.08 | 13.15 | 13.67 | 5.4 / 8.2 |
| m2_cycle seed 4 | 9.43 | 13.02 | 13.45 | 5.7 / 8.1 |
| m2_cycle seed 5 | 7.98 | 11.02 | 12.67 | 4.8 / 7.6 |
| m2_cycle seed 6 | 8.16 | 11.35 | 12.44 | 4.9 / 7.5 |
| m2_cycle seed 7 | 8.96 | 12.48 | 12.87 | 5.4 / 7.7 |
| m2_cycle seed 8 | 9.43 | 13.07 | **15.28** (frame 286, rising above the walls after the skip at 240) | 5.7 / **9.2** |
| m2_cycle seed 9 | 9.12 | 13.05 | 13.64 | 5.5 / 8.2 |
| m2_cycle seed 10 | 8.99 | 11.79 | 13.53 | 5.4 / 8.1 |
| m3_tour | 8.39 | 11.14 | 12.26 | 5.0 / 7.4 |
| m4_takeover | 6.77 | 9.78 | 11.36 | 4.1 / 6.8 |

**12x12 (the SYCL default, for comparison):**

| Run | mean ms @150 | p95 | worst ms @150 | est. @250 mean / worst |
|---|---|---|---|---|
| m2_cycle seed 1 | 7.46 | 9.13 | 10.45 | 4.5 / 6.3 |
| m2_cycle seed 2 | 6.89 | 9.04 | 9.99 | 4.1 / 6.0 |
| m2_cycle seed 3 | 7.32 | 9.17 | 10.55 | 4.4 / 6.3 |
| m2_cycle seed 9 | 7.28 | 9.04 | 10.43 | 4.4 / 6.3 |
| m3_tour | 7.30 | 9.11 | **11.35** | 4.4 / **6.8** |

Seed 8 at 16x16 ran twice (both streams) and gave the same 15.28 ms, so
the runs are deterministic. 0 of 10,900 16x16 frames are over 16.7 ms even
at 150 MHz.

Why 16x16: the Tufty gate is worst <= 16.7 x 250/150 = 27.8 ms modelled at
150 MHz, and the target with headroom is <= ~22 ms (the panel push runs on
core 0 in parallel and SRAM contention between the cores is not modelled).
16x16 is 15.28 ms, 69% of that target and ~9.2 ms of 16.67 ms at 250 MHz
(55% of the frame, 45% free). 16 is also the cart's ceiling
(`maze.max_size`; `-Dmaze_size` clamps to 4..16), so there is no larger
size to try without a cart change. The worst frames are the RISE/DESCEND
views from above, as on the SYCL badge (PLAN.md A4 result). The cost of
the bigger maze on the Tufty is ~2.4 ms more worst frame and ~1 ms more
mean; the gain is a maze that takes noticeably longer to walk and a wider
OVERHEAD view.

## 8. Risks and unknowns

* **`cart.rand()` returns 0 on both badges, so every boot shows the same
  mazes.** `platform_cart_ram.zig rand()` shifts in bit 16 of `0x4006000C`
  32 times. On the RP2350 that address is `ACCESSCTRL_GPIO_NSMASK0`
  (ACCESSCTRL base 0x40060000; the ROSC is at 0x400e8000 and RANDOMBIT at
  0x400e801c), reset value 0, and neither the SYCL OS, the Tufty OS nor
  microzig writes it. So `rand()` is 0, `rng.Xorshift.init(0)` falls back
  to the fixed state 0x9e3779b9, and the first maze after every power-on or
  HOME restart or relaunch from the arcade menu is the same one, followed by the same sequence of mazes
  (the stream advances, so successive mazes within a run do differ, and the
  actor placement follows the same stream). It is an upstream SYCL bug.
  **Fixed for the Tufty** on the snouty-badge `tufty` branch (9cbf968,
  [../CARTS.md](../CARTS.md)): the `-Dbadge=tufty` badge build xors
  murmur3-mixed `micros_since_boot()` into the seed in `start()`, which in
  the arcade runs when someone picks the cart, and stirs the stream once
  more at the first button press (for a power-on straight into the
  single-cart build, where only the first maze is then fixed). The SYCL
  build still shows the fixed sequence. badge-bench fakes the register with a seeded PRNG, so
  its `--seed 1..10` runs are ten different mazes, not the one hardware
  shows; the wasm preview with `--call debug_set_size:16 --call
  debug_set_seed:0` shows the hardware sequence.
* **Present rate on the real panel.** Pacing is on TIMER0, not TE, so expect
  occasional tearing on fast pivots.
* **Memory contention.** badge-bench does not model core 0's panel DMA
  reading SRAM while core 1 renders. The 16x16 worst frame keeps ~45% of
  the frame free at 250 MHz, which should cover it.
* The name strip says "ADRIAN HATCH / ANTITHESIS" (`overlay.zig`). That is
  fine on Adrian's badge, but a cart-side edit for anyone else.
* Neopixel writes (zero) go to the IPC block and need no OS work.
* The autopilot resumes after 5 s, so a misheard tap/hold does not strand
  the player.
* Untested on hardware, like every Tufty build so far (snouty-run.md
  section 6 lists the bring-up checks).
