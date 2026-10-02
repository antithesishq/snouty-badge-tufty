# snouty-maze on the Tufty

Snouty Maze is a Windows 3D Maze screensaver clone with a software
rasterizer, at 60 fps. An autopilot walks the maze, and the stick can take
the camera over. The sources are in `snouty-badge/carts/snouty-maze`
(48c0d18). The map primitives are defined in [README.md](README.md).

## 1. Controls the cart reads

These come from `cart/src/main.zig` `update()` and `autopilot.stick()`. The
edges are from `input.zig`.

| State | Input | Effect |
|---|---|---|
| WALK / TURN | any direction | Takeover: MANUAL starts. Other states ignore the stick |
| MANUAL | Up/Down (edge, held repeats) | One cell forward/back. A wall blocks it |
| MANUAL | Left/Right (edge) | Pivot 90 degrees |
| MANUAL | 5 s with no stick | The autopilot resumes from the current cell |
| all autopilot states | A (edge) | Skip to PAUSE (starts the finish sequence and cuts GROW short; ignored in TELEPORT) |
| all autopilot states | Start (edge) | Toggle the name strip permanently on/off. It shows during OVERHEAD anyway |
| all autopilot states | Select (edge) | Flips `leds.enabled`. A no-op, because the LEDs are compiled out |
| debug builds only | B+Select (either order) | Toggle fly mode (`-Ddebug_overlay=true`) |
| fly (debug) | stick, A/B + Up/Down, A+B, Start, Select | Fly camera, pitch/rise, new maze, reset, overlay |

B is read only in the debug fly mode. Click is never read. The cart is a
screensaver, so "gameplay" is optional walking.

## 2. Proposed Tufty map

This uses the same split layout as bugs and snoutenstein, so the carts feel
alike.

| Tufty | Controls | Notes |
|---|---|---|
| UP / DOWN | up / down | step forward/back, and the takeover |
| A | left | pivot left |
| B | right | pivot right |
| C, tap (< 400 ms) | a | skip to the finish sequence |
| C, hold (>= 600 ms) | start | toggle the name strip |

* There are no chords. Any chord built from direction buttons would leak a
  takeover step or pivot in its first frame, unless the OS used a `chord_ms`
  delay. Tap/hold on C has no leak. Skip fires on release, which is fine for
  a screensaver.
* Select (the LED flag) and the B+Select fly chord are not mapped. They do
  nothing in a release build.
* If the OS adopts HOME tap = start, C can be a plain direct `a`.
* No cart change is needed.

## 3. Scale mode: **fit** (crop is acceptable)

* The bottom 24 rows hold the name strip: the Iris icon at y 104..127 and the
  text at 106..113 and 116..123 plus a 1 px shadow to 124. Crop drops the
  icon's bottom 4 rows and the shadow of line 2. That is visible but minor.
* The debug overlay at y 0..18 only exists in `-Ddebug_overlay` builds.
* Fit artifacts: the fade overlay (`overlay.fade`) uses a 4x4 Bayer pattern.
  With nearest-row duplication some pattern rows are single and some double,
  so the fades band slightly. The textured walls themselves are fine.
* Crop keeps square pixels and an exact 2x, but loses 8 rows of view. Pick
  fit by default and leave crop as the per-cart M3 option.

## 4. Build facts

* RAM cart by default. The XIP build exists, but the Tufty uses RAM.
* Options: `-Ddebug_overlay` (default false; it starts the overlay on and
  compiles in B+Select fly), `-Dneopixels` (default false, LED effects
  compiled out) and `-Dmaze_size=N` (4..16, default 12; 16 is too slow on the
  SYCL badge). It does not read `-Dsound` and has no audio.
* Sizes at 48c0d18: `.text` 67,700, `.data` 3,264, `.bss` 78,016 (16 KB of
  that is colour grids).
* API extras: `cart.rand()` (the maze seed in `start()`; it reads the RP2350
  ROSC RANDOMBIT directly), `micros_since_boot` (render timing),
  `neopixels` (zero writes only) and `rect`/`text`. It does not use tone2, the
  light sensor or romfs.

## 5. Perf

| Source | mean ms | worst ms | budget |
|---|---|---|---|
| PLAN M4 result, `m2_cycle` seeds 1..10 (900 frames each), calibrated busy | 7.06..7.91 | **11.36** (seed 9, a rise/descend view) | 16.7 (cart's own goal 12.0) |
| Re-run 2026-10-02, 48c0d18, `m3_tour.json` 600 frames | 7.20 | 11.35 | 16.7 |
| 16x16 maze (`-Dmaze_size=16`): mean from `m4_takeover`, worst from `m2_cycle` (PLAN A4) | 6.73 | 14.60 | 16.7 |
| Tufty at 250 MHz (x 0.6), 12x12 | ~4.4 | ~6.8 | 16.7 |
| Tufty at 250 MHz, 16x16 | ~4.0 | ~8.8 | 16.7 |

This is the FP-heaviest of the 60 fps carts (11% `fp_dep` stall cycles). The
stalls are cycles, so they scale with the clock. At 250 MHz a 16x16 maze fits
with about 45% headroom, and `-Dmaze_size=16` is the obvious Tufty upgrade. It
needs no code change, but it is a different build flag from the SYCL build.

## 6. Risks and unknowns

* **`cart.rand()` needs the ROSC running.** If the Tufty OS stops the ring
  oscillator (some clock setups do), RANDOMBIT is constant and every boot
  gets the same maze. Keep the ROSC on in the clock init.
* The name strip says "ADRIAN HATCH / ANTITHESIS" (`overlay.zig`). That is
  fine on Adrian's badge, but a cart-side edit for anyone else.
* Neopixel writes (zero) go to the IPC block and need no OS work.
* The autopilot resumes after 5 s, so a misheard tap/hold does not strand
  the player.
