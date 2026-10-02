# snoutenstein on the Tufty

Snoutenstein 3D is a 60 fps tank-control raycaster FPS with hold-to-rewind
and an attract demo. The sources are in `snouty-badge/carts/snoutenstein`
(48c0d18). The cart is the unmodified RAM-mode build, embedded in the Tufty
OS exactly as snouty-run is (see [snouty-run.md](snouty-run.md) section 5
for how the OS runs a cart). The map primitives are defined in
[README.md](README.md) and `src/controls_map.zig`.

## 1. Build and flash

```sh
zig build -Dcart=snoutenstein     # scale defaults to fit for this cart
# -> zig-out/firmware/snouty-tufty-snoutenstein.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/cart/snoutenstein.{elf,bin}     (the embedded cart)
zig build -Dcart=snoutenstein -Dscale=crop            # if the top HUD text may go
```

The cart is built with its defaults: `-Dsound=false` (it boots silent; the
title can still toggle sound on) and `-Dneopixels=false`. The levels are
host-generated in the monorepo, so the cart's comptime stays light.

Flash as in [../DEPLOY.md](../DEPLOY.md). HOME short press restarts the cart
from a fresh RAM image (and resets the button mapper, so autowalk is off);
HOME held 1 s reboots into BOOTSEL.

UF2 facts (checked with `snouty-badge/tools/uf2_info.py`): 431 blocks,
family `0xe48bff59` (RP2350_ARM_S), targets `0x10000000..0x1001af00`
(108 KB). That is far below `0x10200000`, and there is no `0x10ffff00`
block. The cart blob (100,124 bytes) sits byte-identical in the payload at
flash `0x10001f24`.

## 2. Controls the cart reads

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
| playing | Up/Down (held) | Walk forward/back (Down wins if both). Doors open when you bump them, there is no use key |
| playing | Left/Right (held) | Turn 2.5 deg/tick. **There is no strafe** |
| playing | A (held) | Fire the current weapon (it has a cooldown) |
| playing | Select (edge) | Next weapon, skipping empty ones. Spray and Debugger auto-equip on first pickup |
| playing | B (edge, then held) | Rewind while held, until the meter runs out |
| playing | Start (edge) | Pause |
| paused | Start (edge) | Resume |
| dead | B (edge) | Rewind out of death (at least a 3 s reserve). Leaving it alive revives you: 2 s without damage, HP at least 25 (HP and portrait frame blink purple; since tufty 7834448). Held 60 frames with no history: restart the level |
| rewinding | B released | Commit. Everything else is ignored |
| intermission/victory | A or Start (edge, after 1 s) | Skip the card. It also auto-advances |

Click is never read. The pause card lists "UP/DOWN WALK, LEFT/RIGHT TURN, A
FIRE, SELECT WEAPON, HOLD B REWIND, START RESUME". The title reads
"PRESS A", "SELECT: SOUND", "B: E1M1  START: TEST".

## 3. Tufty map (`controls_map.snoutenstein`)

### The grip

On the real badge A, B and C sit in a row along the bottom edge below the
screen, and UP/DOWN are on the right side of the front. Held in two hands,
the left thumb covers A/B and the right thumb covers **either** C **or**
UP/DOWN, not both. (README.md's split d-pad assumed right fingers on
UP/DOWN while the thumb holds C; that is not how this badge is held.)

An FPS wants walk + turn + fire at once. With the grip above, turning (left
thumb) combines with either firing or walking (right thumb), never all
three. The cart has no strafe, so walking means forward/back only. What
matters most in play:

1. **Turn + fire**: the fight. Left thumb rocks A/B, right thumb holds C.
   Direct bindings give this with no help.
2. **Walk forward + turn**: getting around corridors. Left thumb on A/B,
   right thumb on UP. Also direct.
3. **Walk forward + turn + fire**: advancing while shooting, circling a
   target. Impossible with one right thumb, so the map adds **autowalk**: a
   double tap of UP latches walking forward, which frees the right thumb for
   C.

### The map

| Tufty | Cart sees | Playing | Title |
|---|---|---|---|
| **A** (held) | left | turn left | - |
| **B** (held) | right | turn right | - |
| **C** (held) | a | fire | campaign ("PRESS A") |
| **UP** (held) | up | walk forward | - |
| **UP** double tap | up, latched | **autowalk** until UP or DOWN is touched, or a rewind | (latches; see section 7) |
| **DOWN** (held) | down | walk back; also stops autowalk | - |
| **A+B** chord (held) | b | rewind; rewind out of death; stops autowalk | E1M1 ("B") |
| **UP+DOWN** tap (< 300 ms) | select (2-present pulse) | next weapon | sound on/off ("SELECT") |
| **UP+DOWN** hold (>= 500 ms) | start (until release) | pause / resume | test level ("START") |
| HOME, short | (OS) | restart the cart | restart the cart |
| HOME, held 1 s | (OS) | BOOTSEL | BOOTSEL |

Autowalk in detail (the `latch` / `unlatch` primitive in
`controls_map.zig`):

* **On**: tap UP (released within 300 ms), then press it again within
  250 ms of that release. Walking is continuous from the first press; the
  only gap is the short release between the taps.
* **Off**: any press of UP (you are back to holding UP to walk, and that
  press never starts a new double tap), any press of DOWN (walk back while
  held), or the A+B rewind chord. Rewinding stops it on purpose: you rewind
  because something went wrong, and walking straight back into it would be
  worse.
* A single tap is a plain nudge forward, so lining up a shot with short UP
  taps never latches. A long walk followed by a quick re-press does not
  latch either (the first press was no tap).
* Firing (C) and turning (A/B) never touch the latch. A weapon swap or a
  pause (UP+DOWN) does stop it, because touching UP or DOWN always does.
* `chord_ms = 0`: a leaked frame before a chord forms is at most one 2.5 deg
  turn or one walk tick. Select and start are edges in the cart, so the
  tap/hold split on UP+DOWN never leaks.
* While rewinding the cart ignores everything but b, so the left thumb just
  lies flat across A+B.

Host tests (`zig build test`, all in `controls_map.zig`):

* `latch: a double tap latches, a touch unlatches`: a single tap stops; a
  double tap keeps up set with nothing held; up+a+left and up+right while
  autowalking; a touch of UP unlatches and is spent (a quick re-press does
  not latch).
* `latch: slow taps and long presses never latch`.
* `latch: DOWN and the A+B rewind drop it`: DOWN gives down only (never
  up+down); A+B gives b only and walking does not resume after it.
* `snoutenstein: rewind, weapon, pause`: A+B = b alone; turn+fire; UP+DOWN
  tap = a 2-present select pulse with no walk; hold = start from 500 ms; over
  all 32 button combinations never click and never select+start together.

### Alternative: plain map (no autowalk)

If players find the latch surprising, drop the `latch`/`unlatch` fields from
the UP, DOWN and A+B bindings. That is the original port note's map:
UP/DOWN walk only while held, everything else as above. Walk + turn + fire
then needs a grip where a right finger reaches UP/DOWN while the thumb
holds C (holding the badge by its right edge). Other options considered and
rejected:

* **A+B = walk forward** (two thumbs-on-one-side Doom style): walking would
  stop all turning, and rewind would need another chord.
* **C = fire + walk**: you could never fire standing still, and backing off
  while firing becomes impossible.
* **Latch on a single tap**: every short nudge forward would turn into a
  walk across the room.

## 4. Screen: fit

* The view is rows 0..103 and the status bar is rows 104..127. The face
  portrait is at y 105..126 and the bars at 118..123.
* The top rows carry text: "<<" (the rewind marker) and "DEMO" at y 0..7.
  The `render_us` readout is always on (`show_render_us = true`) at the top
  right, y 0..7. "DEMO OK/DESYNC" is at y 2 on the title. Crop would cut all
  of them and the bottom of the portrait, so fit is the default
  (`Cart.scale` unset in build.zig's `carts` table).
* The raycast walls are vertical spans, so fit's row duplication (1 row in 8
  is single height) only shows on the floor/ceiling horizon bands and the
  8x8 HUD text.
* The rewind scanlines (`view.scanlines()`) beat against the fit row pattern.
  Cosmetic, and only while rewinding.

## 5. Sound and the FIFO

The cart has one tone2 voice. It boots silent (`-Dsound=false`), and an
UP+DOWN tap on the title toggles it on. The Tufty has no buzzer.

* `tone2` (`platform_cart_ram.zig`) busy-waits for FIFO space, pushes
  CART_TONE (0x27) and returns. It never waits for an answer.
* The Tufty OS reads the FIFO every loop and accepts and ignores TONE,
  VOLUME and TRACE (`cart_host.zig handle_message`). The only time it does
  not read is a present (~7.4 ms) or the one-time start-up time handshake.
* The cart sends at most 3 tone words in one update (a reset `silence()`,
  a sweep retrigger and one event), plus one FRAMEBUFFER_READY per frame,
  which core 0 has already taken before it starts that present. The
  RP2350 FIFO holds 4 words, so even during a present the cart never waits
  on it. The cart never blocks on sound.
* Measured in badge-bench with sound toggled on at the title: 81 CART_TONE
  messages on 81 frames over 900 frames (at most 1 per frame on that run),
  same timing as with sound off.

## 6. Bench

badge-bench (calibrated, `calibrate/calibration.toml`) on
`zig-out/firmware/cart/snoutenstein.elf` (sha256 88e5184b3e20), modelled at
150 MHz; the Tufty estimate is x 0.6 for 250 MHz (core 1 runs from SRAM, so
it scales with the clock).

The input script is the cart-side output of the Tufty map for a play
session: C on the title (campaign), a double tap of UP into autowalk while
turning and firing, a weapon tap, the A+B rewind for 2 s (which drops the
autowalk), manual UP walk + fire, an UP+DOWN hold to pause and another to
resume, then walk + turn + fire again.

```sh
cd /home/exedev/snouty-badge
./badge-bench/bench.sh <worktree>/zig-out/firmware/cart/snoutenstein.elf \
  --script tufty_play.json --frames 900 --png 150 --symbols
```

| Run | mean ms @150 | worst ms @150 | est. @250 mean / worst | budget |
|---|---|---|---|---|
| 900 frames, play + autowalk + rewind + pause | 2.33 (p95 3.27) | 6.91 (frame 401, the first rewind frame) | 1.4 / 4.1 | 16.7 |
| The same with sound toggled on at the title | 2.33 (p95 3.27) | 6.91 (frame 401) | 1.4 / 4.1 | 16.7 |
| PLAN M6 (`m6_debugger.json`, Debugger burst filling the view) | 2.91 | 5.72 | 1.7 / 3.4 | 16.7 |

Start-up is 3.42 ms modelled. 0 of 900 frames over budget (the worst uses
41% at 150 MHz, ~25% at 250). Hot functions: `render.view.draw` 61%,
`api.text` 13%, `api.rect` 10%. The PNGs show the campaign in play at
frames 150/300, the rewind tint and "<<" marker at 450, and play after the
rewind at 600/750.

Frame pacing is the same as demosnout's ([demosnout.md](demosnout.md)
section 5): vsync at 16.67 ms, `no_copy_full_frame`, a present of ~7.4 ms on
core 0 against a render of at most ~4.1 ms on core 1.

## 7. RAM

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (OS zeroes it) |
| 0x20035100 | `.cart_descriptor`, then `.text` (96,220), `.ARM.extab`, `.ARM.exidx`, `.data` (3,308) to 0x2004d81c |
| 0x2004d820..0x20063b7c | `.bss`, 90,972 bytes |
| 0x20063b7c..0x20080000 | ~113 KB free for the stack |

The entry `_start` is 0x20035115. `cart.bin` starts with CART_MAGIC then V1.

## 8. Risks and unknowns

* **Stray autowalk.** The map cannot see the cart's mode. A double tap of UP
  on the title, a pause or an intermission card latches walking, and the
  next level starts with the player walking. Reaching the exit while
  autowalking carries into the next level the same way. Touch UP or DOWN to
  stop. If this annoys players, use the plain map (section 3).
* **Grip.** The map is built on the reported grip (right thumb on C or
  UP/DOWN). Check on the badge that UP+DOWN can be pressed together by one
  thumb; if not, weapon and pause need another chord (B+C and A+C both
  collide with turn+fire).
* **Title labels.** Since the snouty-badge `tufty` commit 9cbf968 the cart
  is built with `-Dbadge=tufty` and prints Tufty names: "PRESS C",
  "UP+DN: SOUND OFF", "A+B: E1M1", "HOLD UP+DN: TEST", "HOLD A+B: REWIND"
  on death, and a pause card with autowalk ("DOUBLE UP AUTO", see
  [../CARTS.md](../CARTS.md)). A long UP+DOWN on the title opens the test
  level, which is harmless but not wanted at the show.
* **Attract demo.** It is driven by recorded input; the map does not touch
  it. A press of A, B, C, UP or DOWN takes over. Select alone would not,
  but an UP+DOWN tap usually leaks one UP or DOWN frame first, so it takes
  over too. A latched UP from the title is already high, so it is no
  takeover edge, but the player then walks from the moment they take over.
* **Determinism.** "DEMO OK" on the title after an attract run is a free
  hardware determinism test on the Tufty.
* Untested on hardware, like every Tufty build so far (snouty-run.md
  section 6 lists the bring-up checks).
