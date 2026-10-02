# snouty-bugs on the Tufty

Snouty Bughunt, a 60 fps side-on bullet-hell shooter with rewind. The sources
are in `snouty-badge/carts/snouty-bugs` (submodule at 48c0d18). The map
primitives (direct, chord, tap/hold) are defined in [README.md](README.md).

## 1. Controls the cart reads

There are two edge detectors in `cart/src/input.zig`. `meta` is stepped every
frame and drives the state machine. `world.w.input` is stepped once per
simulated tick, and it is logged and replayed by the rewind.

| State | Input | Effect |
|---|---|---|
| title | A or Start (edge) | Normal game |
| title | B (edge) | Hardcore game (no rewind stock) |
| playing | Up/Down/Left/Right (held) | Move the ship, 8 directions. Up/Down also bank the sprite |
| playing | A (held) | Zapper, one bolt every 6 ticks |
| playing | B (edge, then held) | Manual rewind, 2 ticks per frame, paid from fuel. It lasts while B is held |
| playing | Start (edge) | Pause |
| paused | Start (edge) | Resume |
| manual rewind | B released | Resume. The stick, A and Start are ignored |
| dying, auto rewind | (none) | All input ignored |

Select and click are never read. SPEC.md's "Select toggles sound" and the
attract/demo takeover are not built (M6 was never done), and the cart has no
audio. The title card reads "A PLAY / B HARDCORE". The pause card reads
"JOYSTICK FLY, HOLD A FIRE, HOLD B REWIND, START RESUME".

## 2. Proposed Tufty map

The cart needs steering in four directions, held fire and held rewind at the
same time. PLAN.md's default map puts left on A and right on C, which leaves
the fire button to a thumb that is already steering. A split layout works
better here. The left thumb rocks A/B for left/right, the right fingers work
UP/DOWN on the edge, and the right thumb holds C to fire.

| Tufty | Controls | Notes |
|---|---|---|
| A | left | left thumb |
| B | right | left thumb (rock A/B like a d-pad) |
| UP / DOWN | up / down | right fingers on the edge |
| C | a | fire, right thumb, held |
| chord A+B (held) | b | rewind (hold), and Hardcore on the title |
| chord UP+DOWN | start | pause/resume, and Normal on the title |

* `chord_ms = 0`. Before a chord completes, one frame of left/right or
  up/down can leak through. That is harmless: left+right and up+down cancel
  in `player.zig`, and the rewind ignores the stick.
* Diagonals plus fire are one button per hand plus the right thumb, so they
  all work. The one weak spot is pressing A+B flat with one thumb while
  steering. You stop steering to rewind, but the rewind ignores the stick
  anyway.
* The on-screen labels are wrong for the Tufty: "A PLAY" means C, "HOLD B"
  means A+B. The OS controls card (README) covers this.
* If UP/DOWN turn out to be front-face buttons under the right thumb, the
  thumb cannot hold C at the same time. Then fall back to OS autofire: hold
  the `a` bit while any of A/B/UP/DOWN is held, plus a 45-frame hold-over.
  Do not hold `a` permanently. The `meta` detector starts at zero, so a
  constant `a` makes a press edge on frame 1 and skips the title at boot.
* No cart change is needed.

## 3. Scale mode: **fit**

* The HUD is rows 0..7: score text at y 0, the fuel bar at y 1..6, and "HARD".
  Crop would cut it in half, so do not use crop.
* The ship's y range goes down to row 125 (`max_y = 125 - cell_h`). The title
  "Antithesis" is at y 116..123.
* Fit artifacts: 16 of 128 rows show once instead of twice. So 1 px bullets,
  the 1 px hitbox dot and the fuel-bar outline flicker between 1 and 2 rows as
  they move, and the 8x8 text has one short row per glyph. That is mild and
  much better than losing the HUD. Native (160x128 at 1:1) makes the bullets
  too small to read.

## 4. Build facts

* RAM cart by default. An XIP twin builds with `-Dcart-mode=xip`, but the
  Tufty uses RAM.
* `.optimize = .ReleaseSmall`. The cart has no build options: it reads no
  `-Dsound`, `-Dneopixels` or `-Ddebug_overlay`. A build-time `gfx` module is
  converted from `assets/gen/*.png`.
* Sizes at 48c0d18 (`size -A`, built 2026-10-02): `.text` 52,740, `.data`
  4,268, `.bss` 17,560. The CLAUDE.md budget is `.text`+`.data` < 160 KB.
* API extras: `micros_since_boot` (the game seed), `rect`/`hline`/`vline`/`text`
  and the framebuffer. It does not use tone2, neopixels, the light sensor,
  `cart.rand` (it has its own world rng) or flash/romfs.
* Double buffer is `.no_copy_full_frame`, with vsync 1000/60 ms.

## 5. Perf

| Source | mean ms | worst ms | budget |
|---|---|---|---|
| badge-bench README (2026-09-29, calibrated busy) | 7.49 | 10.50 | 16.7 |
| Re-run 2026-10-02, 48c0d18 ELF, `m1_play.json` 600 frames, calibrated | 7.11 | 10.43 | 16.7 |
| Tufty at 250 MHz (x 150/250) | ~4.3 | ~6.3 | 16.7 |

That leaves about 60% headroom at 250 MHz. `m1_play` does not reach the
boss. SPEC section 14 requires 60 fps during the boss on hardware, so check
the boss on the Tufty as well. The real limit will be the OS present (panel
transfer and pacing), not the cart.

## 6. Risks and unknowns

* Labels and help cards name SYCL buttons. Without the controls card, players
  press A expecting to fire.
* The hold-B rewind has to see B held for every frame of the hold. The chord
  must stay asserted for as long as both buttons are down, with no debouncing
  gaps. A one-frame drop ends the rewind, and the next press costs a fresh
  step.
* The rewind log stores raw `Controls` words. The OS map is applied before
  the cart reads them, so replays are unaffected.
* The `micros_since_boot` seed reads TIMER0 directly. The Tufty OS must run
  TIMER0 at 1 MHz (the TICKS block, from the 12 MHz XOSC), or the timing and
  seed go wrong. This applies to every cart.
* No audio, LEDs or light sensor, so the Tufty-only extras are unaffected.
