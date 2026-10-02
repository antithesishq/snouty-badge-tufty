# Cart ports to the Tufty 2350

One file per cart: the controls it reads, a proposed Tufty map, the scale
mode, build facts, perf and risks. Every cart is the unmodified RAM-mode build
from the `snouty-badge` submodule (48c0d18). snouty-run is covered
separately.

| Cart | One line |
|---|---|
| [snouty-bugs](snouty-bugs.md) | 60 fps shooter. It needs 4 directions + held fire + held rewind. The split layout makes all of them playable with no cart change. Fit; 10.4 ms worst becomes ~6.3 ms |
| [snoutenstein](snoutenstein.md) | 60 fps raycaster. 8 functions on 5 buttons: rewind on A+B, weapon/pause as tap/hold of UP+DOWN. Fit; 5.7 ms worst becomes ~3.4 ms |
| [snouty-maze](snouty-maze.md) | 60 fps screensaver with optional walking. No chords: C tap = skip, C hold = name strip. Fit; 11.4 ms worst becomes ~6.8 ms, so a 16x16 maze fits |
| [demosnout](demosnout.md) | 60 fps demo. A/B/C/UP/DOWN map 1:1 onto a/b/select/up/down. Crop; 5.6 ms worst becomes ~3.3 ms. Largest `.bss` (174.5 KB) |
| [snouty-reflections](snouty-reflections.md) | Ray tracer. Ported with the `tufty20` variant (full15's full scene at 20 fps, on the submodule's `tufty` branch, docs/CARTS.md): 65.7 ms worst at 150 MHz on all four presets, ~39.4 ms at 250 vs 47. full20 is still over (~54 ms). Crop |

## Layout assumption: the split d-pad

Hold the badge in landscape with both hands:

* The **left thumb** rocks between **A and B**.
* The **right thumb** rests on **C**.
* The **right index/middle fingers** work **UP and DOWN** on the right edge.

So steering a cart is left/right on A/B and up/down on UP/DOWN, and C is the
action button. It can be held while steering both axes. PLAN.md's default
(A = left, C = right, B = action) gives the action button to a thumb that is
already steering. That only works for carts with autofire, so these maps do
not use it. The two chords that never collide with play are **A+B**
(left+right) and **UP+DOWN** (up+down), because both pairs cancel in every
cart. **Check this on the badge:** if UP/DOWN are front-face buttons that only
the right thumb can reach, then C cannot be held while steering vertically.
See the fallback in snouty-bugs.md.

## Map primitives the OS needs

* **direct**: a button sets Controls bits while it is held.
* **chord X+Y**: while both are held, set the chord's bits and mask the direct
  bits of X and Y. Per cart, `chord_ms` delays the direct bits of chord
  members so a chord can form without leaking. 0 suits twitch carts (a
  one-frame leak); 60 suits reflections.
* **tap / hold**: on a button or chord, emit a pulse bit on release before
  `hold_ms` (tap), or once held for `hold_ms` (hold).
* **Pulses** last at least 2 cart presents, not 2 OS ticks. Reflections runs
  at 20 fps, and the carts detect edges once per update.
* **autofire** (fallback only): a bit is held while any button of a set is
  held, plus a hold-over. It never runs constantly. snouty-bugs' title would
  see a press edge on frame 1 and skip itself.
* **Optional, OS-wide:** HOME tap (< 500 ms) = a start pulse, HOME hold = menu,
  long hold = BOOTSEL. Start means "pause" in bugs and snoutenstein, and this
  would free a chord slot in snoutenstein, maze and reflections.
* A **controls card** shown before launch: every cart's title or help text
  names SYCL buttons ("A PLAY", "HOLD B REWIND", "SELECT: SOUND").

## Combined map

`dir` = direct. `A+B` / `U+D` = chords. `tap`/`hold` = tap/hold.

| Tufty | snouty-bugs | snoutenstein | snouty-maze | demosnout | snouty-reflections |
|---|---|---|---|---|---|
| A | left | left (turn) | left (pivot) | a (skip/jump) | left (orbit) |
| B | right | right (turn) | right (pivot) | b (hold/close) | right (orbit) |
| C | a (fire, held) | a (fire, held) | tap: a (skip); hold: start | select (picker) | a (freeze, on the press) |
| UP | up | up (walk) | up (step) | up (picker) | up (height) |
| DOWN | down | down (back) | down (step) | down (picker) | down (height) |
| A+B | b (rewind, held) | b (rewind, held) | - | - | select (preset) |
| U+D | start (pause) | tap: select (weapon); hold: start (pause) | - | - | b (dither) |
| chord_ms | 0 | 0 | n/a | n/a | 60 |
| Unmapped | select, click (unused) | click | select (no-op), B+Select (debug only) | start (= A), left/right, click | start (HOME tap restarts into attract), click |
| Scale | fit | fit | fit (crop ok) | crop | crop |
| Cart change | none | none | none | none | `tufty20` variant (`tufty` branch, cfe3046) |

## Perf at 250 MHz (calibrated busy ms at 150 MHz, x 0.6)

| Cart | Budget | 150 MHz worst / mean | 250 MHz est. worst / mean |
|---|---|---|---|
| snouty-bugs | 16.7 | 10.43 / 7.11 | 6.3 / 4.3 |
| snoutenstein | 16.7 | 5.72 / 2.91 | 3.4 / 1.7 |
| snouty-maze 12x12 | 16.7 | 11.36 / ~7.5 | 6.8 / 4.5 |
| demosnout | 16.7 | 5.56 / 1.97 | 3.3 / 1.2 |
| reflections cut20 | 47.0 | 49.73 / 44.62 | 29.8 / 26.8 |
| reflections full20 | 47.0 | 90.48 / 68.47 | 54.3 / 41.1 (over) |
| reflections full15 | 62.7 | 64.83 / 60.63 | 38.9 / 36.4 |
| **reflections tufty20 (shipped)** | 47.0 | 65.72 / 49.98 (all presets) | 39.4 / 30.0 |

Each cart file gives the source of its numbers. The re-runs on 2026-10-02
were made on ELFs built from the submodule in a scratch directory; the
submodule tree was not touched.

## Common risks (every cart)

* **TIMER0 at 1 MHz.** `micros_since_boot` reads TIMER0 directly
  (`platform_cart_ram.zig`). It drives seeds, render timing and reflections'
  path-tracer deadline.
* **`cart.rand()` is 0.** It reads 0x4006000C, which on the RP2350 is
  ACCESSCTRL, not the ROSC (snouty-maze.md section 8). Only snouty-maze
  calls it, and its Tufty build seeds from TIMER0 instead.
* **FIFO messages.** The OS must drain and ignore CART_TONE (0x27),
  CART_VOLUME (0x29) and CART_TRACE. The Tufty has no buzzer, and a full FIFO
  blocks the cart (snoutenstein, once sound is toggled on).
* **The cart window must match the SYCL OS** (load 0x20035100, the IPC block
  and framebuffers at 0x20020000, the same stack top). demosnout uses 263 KB
  of the ~307 KB.
* **Panel bandwidth.** 320x240x2 = 150 KB per frame over 8-bit 8080. Four
  carts are frame-locked at 60 fps (`no_copy_full_frame` + vsync), and
  demosnout's timing slows down with the present instead of dropping frames.
