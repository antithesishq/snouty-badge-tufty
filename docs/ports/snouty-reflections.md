# snouty-reflections on the Tufty

Snouty on the Water is a real-time ray tracer: chrome spheres on a rippling
lake, four presets, and a freeze-frame path tracer (M4). The sources are in
`snouty-badge/carts/snouty-reflections` (48c0d18). The map primitives are
defined in [README.md](README.md).

## 1. Controls the cart reads

All input goes through `app.handle_input()`, which runs once per update (20
updates a second in cut20).

| Input | Attract (default) | Free camera | Frozen |
|---|---|---|---|
| Left/Right (held) | enter free camera, orbit | orbit, 3 orbit frames per update | orbit the frozen view (restarts accumulation) |
| Up/Down (held) | enter free camera, height | height 1.0..1.8 m, 50 mm per update | height |
| A (edge) | freeze (the path tracer takes over) | freeze | unfreeze, time resumes |
| B (edge) | cycle dither: bayer_temporal, blue_noise, palette16, none | same | same (re-quantises the accumulator) |
| Select (edge) | next preset (sunset, midnight, noon, storm) | same | next preset, and restart the path tracer |
| Start (edge) | nothing | back to attract | unfreeze and go back to attract |

Timeouts: free camera returns to attract after 20 s (`20 * fps` frames)
without input. A converged frozen image returns after 60 s. Click is never
read, and there is no HUD or audio.

## 2. Proposed Tufty map

| Tufty | Controls | Notes |
|---|---|---|
| A | left | orbit, left thumb |
| B | right | orbit, left thumb (rock A/B) |
| UP / DOWN | up / down | height, right fingers |
| C | a | freeze/unfreeze, right thumb: the headline feature on one button |
| chord A+B | select | next preset |
| chord UP+DOWN | b | cycle dither |
| C hold (>= 600 ms) | start | back to attract. Optional, the timeouts do it anyway. If used, C is tap = a |

* **`chord_ms = 60` for A/B and UP/DOWN.** A direction press leaves attract
  for free camera and pauses the preset cycle. Without the delay, the first
  frame of a chord would leave attract every time someone changes the
  preset. At 20 fps, 60 ms is about one frame of extra orbit latency, which
  you cannot see.
* Nothing is held together with a fire-style button, so there are no
  ergonomic conflicts.
* No cart change is needed for the map.

## 3. Scale mode: **crop**

* There is no HUD. The names and the Iris logo are traced into the scene
  (the shore texture), away from the edges. The `-Ddebug_overlay` text at
  y 0/8/16 is off by default.
* Crop gives an exact 2x2 and square pixels, so the Bayer, blue-noise and
  palette16 dithers stay regular, and the spheres stay round. In fit, 1 row
  in 8 is single, which breaks the 4x4 dither cells into visible horizontal
  banding. The temporal dither then shimmers unevenly, and the spheres are
  6.7% wider than tall.
* Crop loses 4 rows of sky and 4 rows of near water. Nothing is composed
  there.

## 4. Build facts

* RAM cart by default, built with `.optimize = .ReleaseFast`.
* `-Dreflections_variant=cut20|full20|full15|half30`. The default is cut20,
  the variant that shipped. `-Dreflections_bench=none|height|motion_off` is for
  benches only. `-Ddebug_overlay` exists, and no `-Dsound` or `-Dneopixels`.
* Sizes at 48c0d18 (cut20): `.text` 123,920, `.data` 64, `.bss` 109,672. The
  `.bss` includes the 80 KB path-tracer accumulator. Per PLAN M4 the other
  variants are: full20 110,800/109,552, full15 108,496/109,552, half30
  137,280/109,672 (`.text`+`.data` / `.bss`).
* API extras: `micros_since_boot` only. The frozen path tracer paces itself on
  it (`pt.slice_us`). It does not use rand (the PT has its own integer rng),
  tone2, LEDs, the light sensor or romfs. Vsync is `1000/fps`. Animation runs
  by frame count, so the orbit is 30 s at any fps.

## 5. Perf and the variant choice

Calibrated busy ms at 150 MHz. The budget is 94% of the frame period (47.0
ms at 20 fps, 62.7 ms at 15, 31.3 ms at 30). The Tufty column scales by 0.6.
That is fair for a RAM cart: SRAM runs at the system clock, and the `fp_dep`
stalls (15% of cycles) are cycles too.

| Variant | Scene | Measured worst / mean (150 MHz) | Tufty est. worst / mean | Budget | Tufty verdict |
|---|---|---|---|---|---|
| cut20 (M3.1, worst preset noon) | no glass, no water shadows | 49.73 / 44.62 | 29.8 / 26.8 | 47.0 | ok, 37% spare (M3's midnight/noon stutter goes away) |
| full20 (M2.2) | everything | 73.88 / - | 44.3 / - | 47.0 | stale: before moving spheres |
| full20 (M3, sunset only) | everything, exact shadows per hit | **90.48 / 68.47** | **54.3 / 41.1** | 47.0 | **over**: the mean fits, heavy frames stutter |
| full15 (M3, sunset only) | everything; glass seen directly uses env rays (knob 4) | 64.83 / 60.63 | 38.9 / 36.4 | 62.7 | ok, 38% spare |
| half30 (M3, sunset) | everything at 80x64 | 27.11 / 21.21 | 16.3 / 12.7 | 31.3 | ok |

**Can the full scene do 20 fps at 250 MHz?** Not as full20. The 74.85 ms
figure in the brief is the M2.1 number. Since M3 the spheres move, which
invalidates the static shadow map, and full20 measures 90.48 ms worst. At
250 MHz that is about 54 ms, over the 47 ms budget. Most frames fit (mean
about 41 ms), but the heavy ones drop to 10 fps.

**Recommendation:**
* **M2, zero cart change: full15.** It is the complete scene (glass sphere
  and water shadows back) with a large margin. At 15 fps the motion is less
  smooth than 20.
* **Better, a 2-line cart change: a `tufty20` variant** with full15's knobs
  at `fps = 20`. That is one enum entry in `build.zig`'s `Variant` and one
  switch arm in `variant.zig`; `tests/variant_unit.zig` covers it. The
  `--variant` table in `tools/reference.py` and `check_render.mjs` only
  matters if you want render checks: the picture is full15's. The
  estimate is about 38.9 ms worst against 47, so the whole scene runs at 20
  fps.
* Before choosing either, bench full15 on all four presets
  (`M3_VARIANT=full15 tools/bench_variants.sh --m3 2`). Only sunset was
  measured, and in cut20, midnight and noon run about 4 ms heavier. Scaled,
  that is still about 41 ms, under 47.
* Frozen mode: the slice is wall-clock (`period - 14 ms`), so the Tufty traces
  about 1.67x more per update. That is about 35 s to 256 passes instead of
  58 s, and it needs no change.

## 6. Risks and unknowns

* **TIMER0 at 1 MHz is required.** `pt.step` traces until `micros_since_boot`
  passes its deadline. A wrong tick rate either overruns the frame or starves
  the tracer.
* The 0.6 scaling is the optimistic case. Core 0 reads the cart framebuffer
  every column for the 2x scaler while the cart writes the other buffer, and
  SRAM bank contention there has not been measured. Leave about 10% for it.
  With that, `tufty20` is still fine and full20 is still over.
* An XIP build would be flash-bound and scale worse than 0.6. Stay on RAM.
* Variants are compile-time, so the Tufty UF2 builds the cart with a
  different flag from the SYCL `dist/`. Document it in the Tufty build.zig.
