# snoutenstein on the Tufty

Snoutenstein 3D is a 60 fps tank-control raycaster FPS with hold-to-rewind
and an attract demo. The sources are in `snouty-badge/carts/snoutenstein`
(48c0d18). The map primitives are defined in [README.md](README.md).

## 1. Controls the cart reads

The mode machine is in `cart/src/main.zig`. It detects edges against the last
applied input (`prev_in`). The simulation is in `sim.zig` (`step`,
`update_weapon`).

| Mode | Input | Effect |
|---|---|---|
| title | A (edge) | Campaign (Staging, Production) |
| title | B (edge) | Imported E1M1 |
| title | Start (edge) | Test level (for scripted runs) |
| title | Select (edge) | Toggle sound (`audio.enabled`) |
| title | nothing for 600 ticks | Attract demo (recorded input log) |
| demo | edge on A/B/Start/any direction | Takeover: the world stays as it is and the meter refills. Select does not count |
| playing | Up/Down (held) | Walk forward/back. Doors open when you bump them, there is no use key |
| playing | Left/Right (held) | Turn 2.5 deg/tick. There is no strafe |
| playing | A (held) | Fire the current weapon (it has a cooldown) |
| playing | Select (edge) | Next weapon, skipping empty ones. Spray and Debugger auto-equip on first pickup |
| playing | B (edge, then held) | Rewind while held, until the meter runs out |
| playing | Start (edge) | Pause |
| paused | Start (edge) | Resume |
| dead | B (edge) | Rewind out of death (at least a 3 s reserve). Held 60 frames with no history: restart the level |
| rewinding | B released | Commit. Everything else is ignored |
| intermission/victory | A or Start (edge, after 1 s) | Skip the card. It also auto-advances |

Click is never read. The pause card lists "UP/DOWN WALK, LEFT/RIGHT TURN, A
FIRE, SELECT WEAPON, HOLD B REWIND, START RESUME". The title reads
"PRESS A", "SELECT: SOUND", "B: E1M1  START: TEST".

## 2. Proposed Tufty map

Gameplay needs 8 functions: 4 directions, held fire, held rewind, a weapon
edge and a pause edge. That means 3 chord slots. The free chords are A+B
(turn left+right) and UP+DOWN (walk both ways), because both pairs cancel.
Any chord that includes the fire button collides with fire-while-moving.

| Tufty | Controls | Notes |
|---|---|---|
| A | left | turn, left thumb |
| B | right | turn, left thumb (rock A/B) |
| UP / DOWN | up / down | walk, right fingers |
| C | a | fire, right thumb, held |
| chord A+B (held) | b | rewind, rewind from death, and E1M1 on the title |
| chord UP+DOWN, tap (< 300 ms) | select | next weapon, and sound on the title |
| chord UP+DOWN, hold (>= 500 ms) | start | pause/resume, and the test level on the title |

* The rewind is the core mechanic. A+B fits it well: while rewinding the cart
  ignores every input except b, so the left thumb only has to lie flat across
  A+B.
* `chord_ms = 0`. A leaked frame is at most one 2.5 degree turn or one walk
  tick before the chord.
* Select and start are edges only, so the tap/hold split on one chord does
  not leak. The OS emits a pulse that lasts 2 presents.
* Option: if the OS adopts HOME tap = start (README), use it for pause and
  make UP+DOWN a plain select chord.
* Title: C starts the campaign. A+B is E1M1. A long UP+DOWN opens the test
  level, which is harmless but not wanted at the show.
* No cart change is needed. The labels and help card are wrong for the
  Tufty, so it needs the OS controls card.

## 3. Scale mode: **fit**

* The view is rows 0..103 and the status bar is rows 104..127. The face
  portrait is at y 105..126 and the bars at 118..123.
* The top rows carry text: "<<" (the rewind marker) and "DEMO" at y 0..7. The
  `render_us` readout is always on (`show_render_us = true`) at the top right,
  y 0..7. "DEMO OK/DESYNC" is at y 2 on the title. Crop cuts all of them and
  the bottom of the portrait.
* In fit mode the raycast walls are vertical spans, so row duplication only
  shows on the floor/ceiling horizon bands and the 8x8 HUD text. That is
  acceptable.
* The rewind scanlines (`view.scanlines()`) are thin horizontal lines. They
  beat against the fit row pattern (1-row vs 2-row lines). This is cosmetic,
  and it only shows while rewinding.

## 4. Build facts

* RAM cart by default. The XIP build links, but it is not needed.
* Options: `-Dsound` (default false; `audio.enabled` boots false and Select on
  the title toggles it) and `-Dneopixels` (default false, which compiles the
  LED effects out).
* Sizes at 48c0d18: `.text` 96,220, `.data` 3,308, `.bss` 90,972. The CLAUDE.md
  budget is `.text`+`.data` <= 140 KB and `.bss` <= 120 KB.
* API extras: `tone2` (only when sound is toggled on), `neopixels` (written only
  in `-Dneopixels` builds), `micros_since_boot` (the game seed and
  `render_us`). It does not use `cart.rand` (the sim has its own xorshift), the
  light sensor or romfs.
* Determinism: the sim is all fixed point. The shipped demo replays and checks
  a hash, and "DEMO OK" on the title is a free hardware determinism test on
  the Tufty.

## 5. Perf

| Source | mean ms | worst ms | budget |
|---|---|---|---|
| PLAN M6 (calibrated busy, `m6_debugger.json`) | 2.91 | 5.72 (Debugger burst filling the view) | 16.7 |
| Re-run 2026-10-02, 48c0d18, `m1_walk.json` 600 frames | 2.12 | 3.71 | 16.7 |
| Tufty at 250 MHz (x 0.6) | ~1.7 | ~3.4 | 16.7 |

That is the lightest of the five carts, about 80% idle. A native 320x240
renderer (PLAN M3) would be affordable here first.

## 6. Risks and unknowns

* **Sound toggle and FIFO.** `tone2` (CART_TONE 0x27) busy-waits on the SIO
  FIFO and pushes a word. Once someone toggles sound with a select tap on the
  title, the Tufty OS must drain and ignore CART_TONE/CART_VOLUME (the Tufty
  has no buzzer). Otherwise the cart blocks when the FIFO fills.
* Neopixel writes go to the IPC block only. They are harmless, and the OS
  ignores them, or could map them to the 4 case LEDs later.
* The attract demo is driven by recorded input. The OS map does not touch it,
  but any OS-generated bits (a stray pulse) count as a takeover edge.
* Tap/hold timing has to be measured in real time, not cart frames. The cart
  runs at 60 fps, so the 2-present pulse is 33 ms.
