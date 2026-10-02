# snouty-flyover on the Tufty

Snouty Flyover ("Memory Lane") is a Comanche-style voxel heightfield flight
over a strip of data structures generated on the badge, with a low-poly 3D
anteater as the flyer, locked to 30 fps. An autopilot flies at boot and
presses each district's verb by itself, and any input takes over. The
sources are in `snouty-badge/carts/snouty-flyover` (M4.1). The cart is the
RAM-mode build with its default options plus `-Dbadge=tufty` (the captions
name C, section 2), embedded in the Tufty OS
exactly as snouty-run is (see [snouty-run.md](snouty-run.md) section 5 for
how the OS runs a cart). The map primitives are defined in
[README.md](README.md) and `src/controls_map.zig`.

## 1. Build and flash

```sh
zig build -Dcart=snouty-flyover   # scale defaults to fit for this cart
# -> zig-out/firmware/snouty-tufty-snouty-flyover.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/cart/snouty-flyover.{elf,bin}     (the embedded cart)
zig build                         # also snouty-tufty-arcade.uf2: every cart behind the menu
```

The cart is the last row of build.zig's `carts` table, so it is the last
entry of the arcade menu ("SNOUTY FLYOVER", the default title from the
name; the cart's own boot card says "MEMORY LANE"). The controls line is
`C VERB  A+B BOOST  UP+DN SKIP` (the `blurbs` table). The row passes no
options, so the monorepo builds it with its defaults: `-Dflyover_fps=30`,
`-Dflyover_depth=256`, no debug overlay. That is the shipped SYCL cart
(section 6 says why not 60 fps).

Flash as in [../DEPLOY.md](../DEPLOY.md). In the single-cart UF2 a HOME
short press restarts the cart from a fresh RAM image (the boot card and the
autopilot at row 0). In the arcade UF2 it returns to the menu
([../ARCADE.md](../ARCADE.md)). HOME held 1 s reboots into BOOTSEL.

UF2 facts (the build's `.flash.txt`, `snouty-badge/tools/uf2_info.py` and
a block scan):

* `snouty-tufty-snouty-flyover.uf2`: 342 blocks, family `0xe48bff59`
  (RP2350_ARM_S), targets `0x10000000..0x10015600` (85.5 KB), contiguous.
  Far below `0x10200000` and the arcade's `0x101C0000` budget, and there is
  no `0x10ffff00` block. The cart blob (72,856 bytes) sits byte-identical in
  the payload at `0x100027B8`.
* `snouty-tufty-arcade.uf2` with flyover added (seven carts): 2621 blocks,
  `0x10000000..0x100A3D00` (655.3 KB, 36.6% of the 1792 KB budget),
  contiguous. The flyover image is the last one, at
  `0x100909F0..0x100A2688`, byte-identical.

## 2. Controls the cart reads

These come from `cart/src/camera.zig` `pilot()` and `cart/src/main.zig`
`update()`. The edges are from `input.zig`, sampled once per 30 fps update.

| Input | Effect |
|---|---|
| Left / Right (held) | Bank and turn (roll shears the horizon, bank-to-turn yaw, x wraps). Takes manual control |
| Up / Down (held) | Pitch: **Up dives** (horizon rises), **Down climbs**; moves the cruise altitude. Takes manual control |
| A (held) | Boost: 0.75 -> 1.875 cells per frame, the fog pulls in, the horizon drops 8 rows. Takes manual control |
| B (edge; held counts as input) | The district verb: HEAP collect garbage, SORT shuffle, TREE insert a key, HASH rehash, STACK push a frame (overflow after 10), PIPELINE burst the pipe, on a Bus send a packet. Takes manual control |
| Select (edge) | Skip to the next Bus + district pair: three black frames with its card while the ring refills, then flight resumes. **Keeps the autopilot flag** |
| Start (edge) | Toggle autopilot / manual flight |
| 450 frames (15 s) without stick, A or B | The autopilot takes over again |

Click is never read. On the SYCL badge Start+Select belongs to the OS (exit
to the menu) and the joystick click to the FPS overlay; neither is ever
sent here. The cart has no sound and never writes the neopixels.

The on-screen text: the boot card ("MEMORY LANE / generated on badge /
30 fps"), a title card per segment at y 4..33, and the caption at the
bottom-left, which names the verb as "B: collect garbage", "B: send a
packet" and so on. The Tufty build (`-Dbadge=tufty`, snouty-badge `tufty`
c77fd61) reads "C: collect garbage", "C: send a packet" and so on, since
C is the verb there (section 3; docs/CARTS.md has the string table and
[tufty-labels-flyover.png](tufty-labels-flyover.png) the before/after).

## 3. Tufty map (`controls_map.snouty_flyover`)

| Tufty | Cart sees | Does |
|---|---|---|
| **A** | left | bank left |
| **B** | right | bank right |
| **UP** | down | climb |
| **DOWN** | up | dive |
| **C** | b, at once, while held | the district verb |
| **A+B** (held) | a | boost while held |
| **UP+DOWN, tap** (released within 300 ms) | select, pulse on release | skip to the next district |
| **UP+DOWN, hold** (500 ms) | start, until release | autopilot on/off, once per hold |
| HOME, short | (OS) | restart the cart (arcade: back to the menu) |
| HOME, held 1 s | (OS) | BOOTSEL |

`chord_ms = 60`. The four direction buttons are all chord members, so
their bits start 60 ms after the press (about two 30 fps frames; a tap
shorter than that still sends one 2-present pulse). C is in no chord and
acts on the press.

Why this map:

* **Split d-pad**, as in the other ports (README.md): the left thumb rocks
  A/B to bank, the right thumb works UP/DOWN to climb and dive, or C.
* **C is the verb.** It is the one action an attendee is invited to press
  (every district has one, and the caption names it), so it gets the one
  button that is never delayed or masked.
* **A+B = boost.** Left and right cancel in the cart, so a flat left thumb
  across both is a clean "go fast". The right thumb can still climb or
  dive while boosting. Steering resumes once both A and B are up.
* **UP+DOWN = Select / Start as tap / hold**, as snoutenstein's weapon /
  pause chord. The skip is the fun one, so it gets the tap; the autopilot
  toggle is rarely needed (any input already takes over, and 15 s idle
  hands back), so it gets the hold. Tap and hold are exclusive, so Select
  and Start are never sent together.
* **UP climbs.** The cart's stick is a flight stick (push up = nose down).
  The Tufty's UP and DOWN are labelled arrow buttons on the side of the
  case with nothing to push forward, so UP moves the flyer up. The swap is
  two fields in the map if the SYCL feel is wanted.
* **Why chord_ms 60 and not 0** (bugs and snoutenstein use 0): in this cart
  a leaked direction is not harmless. One frame of up or down before a
  UP+DOWN chord completes takes manual control. Then a hold meant as
  "autopilot off" would flip it back on (the leak turns it off, the Start
  edge toggles it on), and a skip taken under the autopilot would drop it.
  60 ms of extra latency on banking and pitch is invisible in a 30 fps
  flight whose roll and pitch ease over several frames.

Alternatives (not built; each is a map edit):

* **C hold = boost**, verb on a C tap: the verb would fire on release, up to
  300 ms late, and boosting would cost the right thumb's climb/dive. Worse.
* **A+B = verb, C = boost (held):** the verb would cost a 60 ms chord
  delay and both steering buttons, and holding C to boost would cost the
  right thumb's climb/dive. Worse.
* **UP = up (dive), the SYCL stick sense:** one swap, see above.
* **No Start at all**, UP+DOWN = plain Select (on the press, no tap delay):
  the autopilot already comes back after 15 s. Possible, if the hold is
  never found.

Host tests (`zig build test`, 7 for this map): `for_cart` picks the map;
each direction button gives exactly its one control from 64 ms and drops on
release, and C gives `b` from the first loop; a 5 ms C tap and a 20 ms A
tap (inside `chord_ms`) still reach a 30 fps cart once; A+B formed 30 ms
apart is boost on every update with no bank leak, also with UP held, and the
member still held after the release stays masked; an UP+DOWN tap formed
40 ms apart is one Select edge with no Start, no pitch and the autopilot
still on; an UP+DOWN hold is one Start edge per hold (autopilot on -> off ->
on) with no pitch leak; bank, pitch and C together give one verb edge and
nothing else; all 32 button combinations held for 1.2 s never send click
and never Select with Start. The tests run a model of the cart's `pilot()`
(30 fps updates over a 1 ms OS loop: Start edge toggles, any direction, A
or B takes manual control).

## 4. Screen: fit

* The caption is drawn at y 119..126 with a 1 px shadow to 127. Crop drops
  rows 124..127, which cuts the bottom three rows of every caption glyph
  and its shadow. So the default is fit (the `carts` row has no `scale`).
* The title cards start at y 4 (4..33), so crop would keep them, and the
  `-Ddebug_overlay` timing in the top right is not in this build.
* Fit artifacts: 16 of 128 rows show once instead of twice. The fog uses a
  temporal dither and the horizon shears with the roll, so the uneven rows
  are hard to see in motion. The 8x8 caption and card text get one short
  row per glyph, as in every fit cart.
* `-Dscale=crop` and `-Dscale=native` still work in the single-cart build.

What you should see after power-on (~0.3 s panel bring-up): the "MEMORY
LANE" card over the first Bus, the anteater flapping in the middle of the
screen, then the autopilot flies Bus, HEAP (the garbage collector wall),
Bus, SORT (live quicksort bands), Bus, TREE, Bus, HASH, Bus, STACK (the
canyon dive) and PIPELINE (the mirror lake with the Iris sun), pressing
each verb once. Press any of A/B/UP/DOWN/C to fly yourself.

## 5. RAM and frame pacing

The cart ELF lays out exactly as on SYCL:

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (OS zeroes it) |
| 0x20035100 | `.cart_descriptor`, then `.text` (71,392), `.ARM.extab`, `.ARM.exidx`, `.data` (200) to 0x20046C98 |
| 0x20046C98..0x2006E518 | `.bss`, **161,664 bytes** (the 128 KB map ring at depth 256, the 4 KB fog table) |
| 0x2006E518..0x20080000 | 72,424 bytes free for the stack |
| 0x20080000 | initial MSP |

The image is 72,856 bytes. `cart_image.validate` accepts it (the arcade
build does not dim its row). The cart calls `set_vsync_enabled(1000/30)`
and runs `no_copy_full_frame`; the Tufty OS paces presents on TIMER0 at
33,333 us ([demosnout.md](demosnout.md) section 5 has the pacing). A
present is ~7.4 ms on core 0, well inside the 33 ms period.

## 6. Bench

badge-bench (calibrated, `calibrate/calibration.toml`, busy ms) on
`zig-out/firmware/cart/snouty-flyover.elf` from this build (sha256
e228c57499a1), modelled at 150 MHz. The Tufty estimate is x 0.6 for
250 MHz (core 1 runs from SRAM, so it scales with the clock). The frame is
33.3 ms (30 fps); the cart's own headroom target is 22 ms at 150 MHz.

The Tufty map run is what the cart sees through this map: a Tufty button
timeline was run through `controls_map.snouty_flyover` (a scratch host
program calling `Mapper.update` every 1 ms, with a cart update every
1/30 s), and the output Controls became a badge-bench `--script`. The
timeline follows the cart's own `m3_verbs.json`: B (bank right) 60..99, UP
(climb) 120..164, C taps at 184, 367, 529, 875, 1220, 1566 and 1912 (each
district's verb), DOWN (dive) 200..229, A+UP 300..339, B+DOWN 700..739,
an UP+DOWN tap at 2141 (Select reaches the cart at 2145, after the
release), A+B 2260..2459 (boost) and an UP+DOWN hold at 2560 (Start at
2575, the autopilot back on).

| Run | mean ms @150 | p95 | worst ms @150 | est. @250 mean / worst |
|---|---|---|---|---|
| `attract.json`, 2400 frames, no input (the boot view) | 8.35 | 12.59 | **15.08** (frame 1823, the PIPELINE lake: the reflection pass) | 5.0 / **9.0** |
| Tufty map, 2700 frames, flying frames | 8.32 | 12.37 | 14.56 (frame 1808, the lake) | 5.0 / 8.7 |
| (same run) boost, frames 2260..2459 | 8.27 | | 10.67 | 5.0 / 6.4 |
| (same run) the Select skip, black frames 2145 / 2146 | | | **28.90** / 22.58 | **17.3** / 13.5 |
| cart's own `m3_verbs.json`, 2600 frames (for comparison) | 8.30 | 12.49 | 28.95 (frame 2141, its skip) | 5.0 / 17.4 |

0 flown frames over 22 ms; the flight uses 45% of the 33.3 ms frame at
150 MHz and ~27% at 250. The attract worst frame matches the cart's M4.1
number (15.07 ms). Hot functions: `_start` (the inlined column march)
89%, `api.text` 7.5%, `memcpy` 2.3%.

The **skip** is the only over-22 frame, and it is the cart's own: the SYCL
build on the cart's own script gives the same 28.95 ms. The first black
frame regenerates 96 ring rows (the cart PLAN.md's estimate was 1 M cycles,
the bench gives 4.3 M). It still fits the 33.3 ms frame at 150 MHz, and at
250 MHz it is ~17 ms, half the frame. Nothing to do for the port.

**Why not 60 fps.** At 250 MHz the worst flown frame is ~9 ms, so
`-Dflyover_fps=60` would fit a 16.7 ms frame, and the skip (~17 ms) would
drop one frame. But the cart moves by frame count, not wall time: at 60 fps
the flight, the dataflow, the cards and the 15 s idle would all run twice as
fast, and the cart's docs keep 60 for experiments. So the Tufty ships the
same 30 fps cart as SYCL. A 60 fps Tufty build would need a cart change
(per-frame steps halved).

## 7. Risks and unknowns

* **The caption said "B: ...".** Fixed: on the `tufty` branch at
  c77fd61 the `-Dbadge=tufty` option (docs/CARTS.md) makes every caption
  "C: ...", matching the arcade's controls line (`C VERB`). The boot card
  and the district cards name no buttons. The SYCL build is byte-identical
  in code and data.
* **UP climbs, unlike the SYCL stick** (section 3). Check that it feels
  right on the badge; the swap is one map edit.
* **The skip frame** (~17 ms at 250 MHz, section 6) is black, so a late
  present there is invisible.
* **Present rate on the real panel.** Pacing is on TIMER0, not TE, so
  expect occasional tearing on hard banks.
* **Memory contention.** badge-bench does not model core 0's panel DMA
  reading SRAM while core 1 renders. The worst flown frame leaves ~73% of
  the 30 fps frame free at 250 MHz.
* `micros_since_boot` (render timing only) reads TIMER0 at 1 MHz as on SYCL
  (README common risks). The cart does not call `cart.rand()`: its world
  comes from fixed seeds (`world.zig`), so every boot flies the same strip,
  as on SYCL and in the bench.
* Untested on hardware, like every Tufty build so far.
