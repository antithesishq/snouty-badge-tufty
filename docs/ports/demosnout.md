# demosnout on the Tufty

Demosnout is a 60 fps demoscene production: 11 parts on a 120 BPM frame
clock, about 110 s per loop, with a part picker. The sources are in
`snouty-badge/carts/demosnout` (48c0d18). The map primitives are defined in
[README.md](README.md).

## 1. Controls the cart reads

These come from `cart/src/main.zig` `update()` and `picker.zig` `handle()`.
All of them are edges (`input.pressed`).

| State | Input | Effect |
|---|---|---|
| any | Start and Select held together | Ignore every button (this is the SYCL OS exit chord) |
| show | Select | Open the part picker. The demo keeps running underneath |
| show | A or Start | Skip to the next part |
| show | B | Toggle hold: auto-advance off/on, with a "HOLD ON/OFF" toast. In `-Ddebug_overlay` builds B toggles the timing overlay instead |
| picker | Up / Down | Move the highlight (it wraps) |
| picker | A | Jump to the part (frame 0) and close |
| picker | B or Select | Close |

Left, Right and click are never read. Nothing is held. The picker hint
reads "A JUMP  B/SELECT CLOSE".

## 2. Proposed Tufty map

| Tufty | Controls | Notes |
|---|---|---|
| A | a | skip in the show, jump in the picker |
| B | b | hold toggle in the show, close in the picker |
| C | select | open/close the picker |
| UP / DOWN | up / down | picker highlight |

* There are no chords and nothing is lost. Start duplicates A, and Left/Right
  are unused.
* The Tufty labels match the cart's A and B, so the picker hint is right
  as-is. Only "SELECT" in the hint means C.
* The map never asserts start+select together, so the cart's
  ignore-everything branch never triggers.
* No cart change is needed.

## 3. Scale mode: **crop** (fit is the fallback)

* The text is clear of the cropped rows. The hold toast is at y 116..123.
  The Intro line is at y 28 and the title around y 64. The Ending credits are
  mid-screen. The picker panel spans y 1..125: its 1 px frame and the top of
  the title band (y 1..3) are cut by crop, but the title text (y 4) and the
  hint (y 116) survive. The `-Ddebug_overlay` readout at y 0 would be clipped,
  but it is off by default.
* What crop buys: an exact 2x2 pixel and square aspect. The copper bars
  (thin horizontal bands), the twister, the sine scroller (16 rows, moving
  every frame), the metaballs and the half-res parts (80x64 indices upscaled
  2x, so 4x4 blocks on the panel) all keep even line widths and smooth
  vertical motion. In fit, 1 row in 8 is single, so the copper bars and the
  scroller judder as they bob, and half-res blocks alternate 3 and 4 rows
  tall.
* What crop costs: 4 rows of picture top and bottom. No part composes
  anything there.

## 4. Build facts

* RAM cart by default.
* Options: `-Ddebug_overlay` only (it changes what B does). It reads no
  `-Dsound` and no `-Dneopixels`, and has no audio or LEDs.
* Sizes at 48c0d18: `.text` 89,240, `.data` 20, `.bss` **174,536**. Its own
  budgets are `.text`+`.rodata` < 110 KB and `.bss` < 190 KB. Stack headroom in
  the 307 KB cart window is about 50 KB (PERF.md). This is the largest RAM
  footprint of the five.
* Start-up runs every part's `init()` (LUTs, voxel map, textures) in 71.9 ms
  before the first frame.
* API extras: `micros_since_boot` (render timing), `rect`/`hline`/`text`. It
  does not use `cart.rand` (each part seeds its own rng from a constant),
  tone2, the light sensor or romfs. The show is deterministic.

## 5. Perf

| Source | mean ms | worst ms | budget |
|---|---|---|---|
| PERF.md M2, full loop 6,660 frames, calibrated busy | 1.97 | 5.56 (a Voxel fade-in) | 16.7 (own rule 12.0) |
| Heaviest part (Voxel), per-part bench | 4.76 | 5.56 | 16.7 |
| Tufty at 250 MHz (x 0.6) | ~1.2 | ~3.3 | 16.7 |

The worst frames are fades (`fx.fade`, one multiply per pixel). There is lots
of headroom. If the panel present can do 60 fps, the demo will. The cart
paces on vsync, so a dropped frame shows as a stretched beat.

## 6. Risks and unknowns

* **Timing is frame-locked.** Parts advance per `update()`. If the Tufty OS
  presents slower than 60 Hz (panel bandwidth: 320x240x2 = 150 KB per frame),
  the whole show slows down rather than dropping frames. Check that the OS
  holds 60.0 fps over a full loop.
* **RAM window.** 174.5 KB of `.bss` plus about 50 KB of stack headroom means
  the Tufty OS must give the cart the same window as the SYCL OS. Load at
  0x20035100, with the stack top where the SYCL OS puts it. If anything of
  the OS's (core 0 stack, line buffers, scratch banks) sits inside that
  window, it is this cart that breaks first.
* Crop leaves the picker's frame line and title band clipped by 1..3 rows.
  This is cosmetic.
