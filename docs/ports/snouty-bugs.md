# snouty-bugs on the Tufty

Snouty Bughunt is a 60 fps side-on bullet-hell shooter with rewind. The
sources are in `snouty-badge/carts/snouty-bugs` (48c0d18). The cart is the
unmodified RAM-mode build, embedded in the Tufty OS exactly as snouty-run is
(see [snouty-run.md](snouty-run.md) section 5 for how the OS runs a cart).
The map primitives are defined in [README.md](README.md) and
`src/controls_map.zig`. This port adds one: **latch** (autofire).

## 1. Build and flash

```sh
zig build -Dcart=snouty-bugs   # scale defaults to fit for this cart
# -> zig-out/firmware/snouty-tufty-snouty-bugs.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/cart/snouty-bugs.{elf,bin}     (the embedded cart)
```

Flash as in [../DEPLOY.md](../DEPLOY.md). HOME short press restarts the cart
at the title (fresh RAM image, autofire off again). HOME held 1 s reboots
into BOOTSEL.

UF2 facts (checked with `snouty-badge/tools/uf2_info.py`): 264 blocks,
family `0xe48bff59` (RP2350_ARM_S), targets `0x10000000..0x10010800`
(66 KB). That is far below `0x10200000`, and there is no `0x10ffff00`
block. The cart blob (57,496 bytes) sits byte-identical in the payload at
flash `0x10001eb8`.

## 2. Controls the cart reads

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

The title checks A before B, so a frame where both rise is a normal game.
Select and click are never read. The title card reads "A PLAY / B
HARDCORE". The pause card reads "JOYSTICK FLY, HOLD A FIRE, HOLD B REWIND,
START RESUME".

Firing is free: no heat, no score cost, no charge shot. The bolt pool (24)
drops shots when full. SPEC.md calls A "Zapper. Hold for autofire", and the
attract AI's rule is "A is held always". So the best play is to fire all the
time, and the only real input is steering, rewinding and pausing.

## 3. Tufty map (`controls_map.snouty_bugs`)

| Tufty | Cart sees | Title | Play |
|---|---|---|---|
| **C** (tap) | a, **latched on** | normal game, autofire on | autofire on (later taps: a fresh A press) |
| **A** | left | nothing | fly left |
| **B** | right | nothing | fly right |
| **UP** | up | nothing | fly up |
| **DOWN** | down | nothing | fly down |
| **A+B** (held) | b | Hardcore game | rewind while held |
| **UP+DOWN** | start | normal game | pause / resume |
| HOME, short | (OS) | restart at the title | restart at the title |
| HOME, held 1 s | (OS) | BOOTSEL | BOOTSEL |

`chord_ms = 0`. Before a chord completes, one frame of left/right or up/down
can leak through. That is harmless: left+right and up+down cancel in
`player.zig`, and the rewind ignores the stick.

### Why autofire on a latch

On the badge, A, B and C sit along the bottom edge under the screen, and
UP/DOWN are on the right of the front face. Held in two hands, the left
thumb covers A/B and the right thumb covers **either** C **or** UP/DOWN. So
"hold C to fire" (the old split-d-pad proposal) cannot fire while flying up
or down. In a side-on shooter that fires to the right, up/down is the main
dodging axis. Every dodge would stop the zapper.

With the latch, one tap of C turns the zapper on for good. Both thumbs then
steer: the left one rocks A/B, the right one rocks UP/DOWN. Rewind (A+B, the
left thumb flat across both) and pause (UP+DOWN, the right thumb) are one
thumb each. No button needs a third finger.

The `latch` primitive (`Binding.latch`):

* **Nothing is latched at boot.** The cart's `meta` detector starts at zero,
  so an `a` held from frame 1 would look like a press and skip the title.
  The latch only turns on at the first press of C, which is meant to start a
  game anyway.
* **The first press latches** the bits on until the mapper is reset. Only a
  HOME restart does that.
* **Every later press re-triggers.** The bits drop for `min_presents` (2)
  presents and rise again. The cart sees a fresh A press, and the zapper
  keeps going. This matters after a game over. The title needs an A edge,
  and A has been steady since the last game, so a tap of C starts the next
  game. In play, the 2-frame gap can delay one bolt by up to 2 ticks.
* A gap beats the 2-present pulse stretch, so two taps on consecutive
  presents still make two edges.

What the player does:

* **At boot:** tap C. The game starts with the zapper on. A+B starts
  Hardcore instead (an `a` edge would win over `b` on the title, so A+B
  never latches). In a Hardcore game started this way, or a normal one
  started with UP+DOWN, **tap C once** to turn the zapper on.
* **In play:** steer with A/B and UP/DOWN. Hold A+B to rewind. Releasing
  either button resumes. The other one stays masked until it is released
  too, so steering comes back after both thumbs lift. UP+DOWN pauses and
  resumes.
* **After a game over:** the title is back with the zapper still latched.
  Tap C for a normal game, or A+B for Hardcore (A is steady, so only B
  rises). Both start with the zapper on.

Host tests (`zig build test`, 7 for this map): nothing is latched at boot
(120 idle frames and steering give no `a` edge); a 3 ms tap of C starts the
game and keeps `a` high for 600 frames; every later C (held, sub-present,
and on consecutive presents) is a new `a` edge, and `a` ends high; steering
diagonals, a 120-frame rewind and a pause all keep autofire, with `b`
asserted on every frame of the hold; A+B gives a `b` edge and no `a` edge,
both at boot and after a game; a fresh mapper (HOME restart) clears the
latch; no button combination ever sends select or click.

### Alternatives (not the default)

* **Hold C to fire** (`.held = bit(.a)` instead of `.latch` on the C
  binding, a one-word change). The labels match the cart's "HOLD A FIRE"
  and the player can stop firing. But fire and vertical steering share the
  right thumb, so you cannot dodge up or down while firing. Use it only if
  the badge turns out to be playable with a finger on UP/DOWN and the thumb
  on C at the same time.
* **Fire while steering** (`a` while any of A/B/UP/DOWN is held, plus a
  ~0.75 s hold-over). This was the fallback in the first proposal. It stops
  firing when the ship sits still lined up with a bug. On the title the
  first steer starts a normal game, and pressing A+B for Hardcore lets A's
  `a` edge win unless `chord_ms` delays it, which a twitch shooter cannot
  afford. Rejected.
* **`a` held from boot.** It skips the title on frame 1, and after a game
  over only A+B or UP+DOWN could start a game. Rejected.
* **A toggle (C on, C off).** After a game over the first C would only turn
  the zapper off, and a second C would start the game. Since firing never
  costs anything, re-trigger beats off.

## 4. Screen: fit

* The HUD is rows 0..7: score text at y 0, the fuel bar at y 1..6, and "HARD".
  Crop would cut it in half, so the default is fit (the `carts` table row
  has no `scale`, so it is `.fit`). `-Dscale=crop` and `-Dscale=native`
  still work.
* The ship's sprite reaches down to row 125 (`max_y = 125 - cell_h`), so
  crop would also clip the ship at the bottom. The title
  "Antithesis" is at y 116..123.
* Fit artifacts: 16 of 128 rows show once instead of twice. So 1 px bullets,
  the 1 px hitbox dot and the fuel-bar outline flicker between 1 and 2 rows as
  they move, and the 8x8 text has one short row per glyph. That is mild and
  much better than losing the HUD. Native (160x128 at 1:1) makes the bullets
  too small to read.

What you should see after power-on (~0.3 s panel bring-up):

1. The title over the scrolling sky: "A PLAY / B HARDCORE" (on the Tufty, C
   and A+B).
2. Tap C: the wave starts and the zapper fires a bolt every 6 ticks without
   any button held. Fly with A/B and UP/DOWN.
3. Hold A+B: the REWIND bar and the world running backwards 2 ticks per
   frame, until fuel or history runs out or a thumb lifts.
4. UP+DOWN: the pause card. UP+DOWN again resumes.
5. When hit with rewinds left, the auto rewind plays by itself. After the
   last one, GAME OVER and back to the title. Tap C to play again.

## 5. Build facts and RAM

* RAM cart (the Tufty uses RAM; an XIP twin builds with `-Dcart-mode=xip`
  on the SYCL side only). `.optimize = .ReleaseSmall`, no build options. A
  build-time `gfx` module is converted from `assets/gen/*.png`.
* API extras: `micros_since_boot` (the game seed), `rect`/`hline`/`vline`/
  `text` and the framebuffer. It does not use tone2, neopixels, the light
  sensor, `cart.rand` (it has its own world rng) or flash/romfs. No audio,
  so the Tufty's missing buzzer changes nothing.
* Double buffer is `.no_copy_full_frame`, with vsync 1000/60 ms. The OS
  paces it the same way as demosnout ([demosnout.md](demosnout.md) section
  5).

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (OS zeroes it) |
| 0x20035100 | `.cart_descriptor`, then `.text` (52,740), `.ARM.extab`, `.ARM.exidx`, `.data` (4,268) to 0x20043198 |
| 0x20043198..0x20047630 | `.bss`, 17,560 bytes |
| 0x20047630..0x20080000 | 231,888 bytes free for the stack and heap |
| 0x20080000 | initial MSP |

The image is 57,496 bytes. `cart_image.validate` accepts it.

## 6. Bench

badge-bench (calibrated, `calibrate/calibration.toml`) on
`zig-out/firmware/cart/snouty-bugs.elf` (sha256 de2b65144c3c, the same
cart build as the monorepo's), modelled at 150 MHz. The Tufty estimate is
x 0.6 for 250 MHz (core 1 runs from SRAM, so it scales with the clock).

The input script is what the cart sees through this map. A Tufty button
timeline was run through `controls_map.snouty_bugs` (a scratch host program
calling `Mapper.update` once per present), and the output Controls became a
badge-bench `--script`. The timeline: tap C at 30, then both thumbs
steering in a 200-frame cycle of diagonals and straights (B+UP, UP, A+DOWN,
none, DOWN, B, A+UP) with no hand on C; A+B held 700..759 (manual rewind);
UP+DOWN at 1000 and 1060 (pause, resume); a C re-trigger at 1400. The cart
sees A from 30 to the end except the 2-frame gap at 1400.

| Run | mean ms @150 | worst ms @150 | est. @250 mean / worst | budget |
|---|---|---|---|---|
| Tufty map, 1,800 frames, autofire throughout | 7.13 (p95 8.92) | 10.39 (frame 225, A+RIGHT, wave on screen) | 4.3 / 6.2 | 16.7 |
| (same run) manual rewind press frame 700 | | 9.13 | 5.5 | |
| (same run) pause card frame 1000 | | 7.91 | 4.7 | |
| Earlier re-run, `m1_play.json` 600 frames (hold A) | 7.11 | 10.43 | 4.3 / 6.3 | 16.7 |

0 of 1,800 frames over budget; the worst frame uses 62% at 150 MHz, ~37%
at 250. Hot functions: the background tile lookup
(`PackedIntSliceEndian(u4).get`) 54%, `draw.draw_bg` 24%, `memcpy` 4%; the
simulation itself is under 2%. So constant fire costs nothing measurable:
the cart's cost is the background, not the bullets. The PNGs (every 100th
frame) show the bolts streaming during steering with no fire button held,
the scanline REWIND view at 700, the PAUSED card at 1000, play again at
1100, and an auto rewind ("OFF BY ONE") at 1500..1700 after a scripted hit.

Two more runs through the same map check the latch in the cart itself:

| Run | What it shows | mean / worst ms @150 |
|---|---|---|
| 4,200 frames: tap C at 30, no steering, C taps every 300 frames from 2100 | An idle ship with autofire holds the line for 70 s (hits, auto rewinds, "GO!"). Each C tap is a 2-frame gap in A and the zapper goes on | 6.98 / 10.20 |
| 3,000 frames: tap C at 30, hold B (fly right into the wave) 60..1999, then idle, C taps every 300 from 2100 | Game over and back to the **title by frame 1600**. The title **stays up for 500 frames with A latched** (no skip). The C tap at 2100 starts a new game (score 0, firing) by frame 2125 | 6.93 / 9.40 |

None of the 9,000 benched frames is over budget.

## 7. Risks and unknowns

* **The labels name SYCL buttons.** "A PLAY" means C, "B HARDCORE" and "HOLD
  B REWIND" mean A+B, "HOLD A FIRE" is automatic, "START" is UP+DOWN.
  Without the OS controls card (README), players press A expecting to fire
  and fly left instead.
* **A Hardcore game started from boot does not fire** until C is tapped.
  This is the price of keeping A+B a clean Hardcore press on the title.
  Worth a line on the controls card: "C: fire on".
* **The rewind must see B on every frame of the hold.** The chord stays
  asserted while both buttons are down (tested for 120 frames), with no
  debounce gaps. A one-frame drop ends the rewind, and the next press costs
  a fresh step. A flat thumb across A and B that rolls off one of them ends
  it too. Check that the A/B pair is comfortable to hold together.
* **The boss is not benched.** Without the wasm test hooks (god mode, warp)
  the bench cannot reach the 66 s boss, and `god` is folded away in the ARM
  build. SPEC section 14 wants 60 fps during the boss on hardware. At ~40%
  of the budget in the worst benched frame there is room, but check the
  boss on the Tufty.
* The rewind log stores raw `Controls` words. The OS map is applied before
  the cart reads them, so replays see the same latched `a`.
* `micros_since_boot` (the seed) reads TIMER0 directly; the Tufty OS runs it
  at 1 MHz as on SYCL (README common risks).
* Untested on hardware, like every Tufty build so far.
