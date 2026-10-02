# demosnout on the Tufty

Demosnout is a 60 fps demoscene production: 11 parts (57 bars) on a 120 BPM
frame clock, 6,840 frames = 114 s per loop, with a part picker. The sources
are in `snouty-badge/carts/demosnout` (48c0d18). The cart is the unmodified
RAM-mode build, embedded in the Tufty OS exactly as snouty-run is (see
[snouty-run.md](snouty-run.md) section 5 for how the OS runs a cart). The
map primitives are defined in [README.md](README.md).

## 1. Build and flash

```sh
zig build -Dcart=demosnout     # scale defaults to crop for this cart
# -> zig-out/firmware/snouty-tufty-demosnout.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/cart/demosnout.{elf,bin}     (the embedded cart)
zig build -Dcart=demosnout -Dscale=fit             # the fallback scale
```

The default scale is per cart now: `Cart.scale` in build.zig's `carts`
table (`.crop` for demosnout, `.fit` otherwise). `-Dscale` still overrides
it.

Flash as in [../DEPLOY.md](../DEPLOY.md). HOME short press restarts the
demo from the Intro (fresh RAM image); HOME held 1 s reboots into BOOTSEL.

UF2 facts (checked with `snouty-badge/tools/uf2_info.py`): 391 blocks,
family `0xe48bff59` (RP2350_ARM_S), targets `0x10000000..0x10018700`
(98 KB). That is far below `0x10200000`, and there is no `0x10ffff00`
block. The cart blob (90,012 bytes) sits byte-identical in the payload at
flash `0x10001e64`.

## 2. Controls the cart reads

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

Left, Right and click are never read. Nothing is held.

## 3. Tufty map (`controls_map.demosnout`)

| Tufty | Cart sees | Show | Picker |
|---|---|---|---|
| **A** | a | skip to the next part | jump to the highlighted part |
| **B** | b | hold on/off (toast bottom right) | close |
| **C** | select | open the picker | close |
| **UP** | up | nothing | highlight up |
| **DOWN** | down | nothing | highlight down |
| HOME, short | (OS) | restart the demo | restart the demo |
| HOME, held 1 s | (OS) | BOOTSEL | BOOTSEL |

* All direct bindings, no chords, so nothing is delayed or masked. Every
  rising bit is stretched to at least 2 presents, so a quick tap is never
  missed by the cart's once-per-update edge detection.
* Start is never sent (A already skips), and neither are Left, Right or
  click. So the cart's Start+Select ignore-everything branch can never
  trigger.
* The picker hint "A JUMP  B/SELECT CLOSE" is right as printed on the Tufty
  for A and B; "SELECT" means C.
* Host tests (`zig build test`): each button gives exactly its one control
  on the first press; all 32 button combinations give exactly the union of
  the direct bits and never start/left/right/click; a 3 ms tap of C still
  reaches the cart over 2 presents.

## 4. Screen: crop

Crop is an exact 2x2 pixel (320x240 from cart rows 4..123). The copper
bars, the twister, the sine scroller and the 80x64 half-res parts keep even
line widths and smooth vertical motion; in fit, 1 row in 8 is single and
those judder as they bob.

What it costs: cart rows 0..3 and 124..127. No part composes anything
there. The hold toast (y 116..123), the Intro line (y 28), titles (~y 64)
and the Ending credits are all inside. The picker's 1 px frame and the top
of its title band (y 1..3) are cut; its title text (y 4) and hint (y 116)
survive. The `-Ddebug_overlay` readout at y 0 would be clipped (off by
default).

What you should see after power-on (~0.3 s panel bring-up, then 72 ms of
part `init()`s on a black screen):

1. Intro (6 s), Plasma, Copper (7 bars), Rotozoomer, Twister, Tunnel,
   Metaballs, Voxel, Snouty head, Fire, Ending (credits, 16 s), then a
   seamless cut back into the Intro. 114 s per loop, forever.
2. C opens the parts list over the running demo; UP/DOWN move, A jumps to
   the part at its frame 0, B or C closes it.
3. B shows "HOLD ON" bottom right for 1.25 s and the current part runs on
   past its length; B again releases it.

The bench PNGs (160x128) match: `badge-bench ... --press SELECT:120-121
--press DOWN:150-151 --press DOWN:170-171 --press A:200-201 --press
B:400-401 --png 50` shows the picker open over the Intro at frame 150
(highlight on Plasma), the Copper part after the jump, and the HOLD ON
toast at frame 450.

## 5. Frame pacing

Demosnout advances one timeline frame per `update()`, so the show's speed
is the present rate. It calls `set_vsync_enabled(1000/60)` once in
`start()` and runs in `no_copy_full_frame` mode (full-frame presents,
double buffered, render overlapped with the previous present).

The Tufty OS path (`cart_host.zig` `handle_message` / `service_present`)
honours it as is; no change was needed:

* The first FRAMEBUFFER_READY_V2 carries `vsync_updated`: `frame_us` =
  16,666 us, and the first present goes at once.
* After that, each present waits for `next_due_us` and then moves it by
  exactly `frame_us` (it only re-anchors if a present is more than a whole
  frame late), so drift does not accumulate.
* The cart's `present_and_acquire` sends READY k only after DONE k-1, and
  renders k+1 while core 0 waits and pushes k. A present takes ~7.4 ms on
  core 0 and a render at most ~3.3 ms on core 1 at 250 MHz, so both fit in
  one 16.67 ms period with ~9 ms to spare.
* TIMER0 ticks at 1 MHz (microzig `start_ticks(1, clk_ref = 12 MHz)`),
  the same clock as the SYCL badge.

An event simulation of exactly that logic (present 7.4 ms, render 1.2 to
9 ms with jitter, 20 us OS loop) gives 6,840 presents in 113.98 s: mean
period 16.666 ms, worst gap 16.68 ms. The loop is 0.004% fast against
114.00 s because `frame_us` truncates to whole microseconds; the SYCL OS
paces on the panel's TE at its own refresh, which is no closer.

## 6. RAM

The cart ELF lays out exactly as on SYCL (it is the same ELF):

| Range | What |
|---|---|
| 0x20020000..0x20035100 | IPC block and the two framebuffers (OS zeroes it) |
| 0x20035100 | `.cart_descriptor`, then `.text` (89,240), `.ARM.extab`, `.ARM.exidx`, `.data` (20) to 0x2004b09c |
| 0x2004b0a0..0x20075a68 | `.bss`, **174,536 bytes** (descriptor range) |
| 0x20075a68..0x20080000 | 42,392 bytes free for the stack (linker reserves 32 KB at 0x20078000) |
| 0x20080000 | initial MSP (`abi.cart_initial_sp`) |

`start_cart` zeroes the whole window 0x20020000..0x20080000, copies the
90,012-byte image to 0x20035100, zeroes the descriptor's BSS again, then
starts core 1 with MSP 0x20080000. `cart_image.validate` accepts it
(BSS end 0x20075a68 < 0x20080000). The OS's own RAM is
0x20000000..0x20020000 (its ELF has a single RAM segment of exactly 128 KB,
data, BSS and stack), so nothing of the OS sits in the cart window.

## 7. Bench

badge-bench (calibrated, `calibrate/calibration.toml`) on
`zig-out/firmware/cart/demosnout.elf` (sha256 c5aa32057cca, the same cart
build as the monorepo's), modelled at 150 MHz; the Tufty estimate is x 0.6
for 250 MHz (core 1 runs from SRAM, so it scales with the clock).

| Run | mean ms @150 | worst ms @150 | est. @250 mean / worst | budget |
|---|---|---|---|---|
| Full loop + 60 (6,900 frames) | 1.97 (p95 4.74) | 5.56 (frame 3965, Voxel fade-in frame 5) | 1.2 / 3.3 | 16.7 |
| 600 frames with picker, jump, hold, skip | 1.12 | 4.39 (frame 180, picker open over the Intro) | 0.67 / 2.6 | 16.7 |

Start-up (every part's `init()`) is 71.7 ms modelled at 150 MHz, ~43 ms at
250 MHz. 0 of 6,900 frames over budget (worst uses 33% at 150 MHz, ~20% at
250). Hot functions: `parts.voxel.render` 28%, `parts.ending.render` 17%,
`memcpy` 13%, metaballs 9%. These match the cart's own PERF.md M2 numbers
(1.97 / 5.56). Core 1 is idle most of each frame, waiting on the present.

## 8. Risks and unknowns

* **Present rate on the real panel.** The pacing is on TIMER0, not TE, so
  expect occasional tearing (the copper bars and scroller show it most).
  If a present ever takes longer than 16.67 ms (bus slower than the
  computed 20.8 MB/s), the show slows down rather than dropping frames.
  Check with a stopwatch: Intro to Intro should be 114 s.
* **Stack.** 42 KB between BSS end and the stack top, the same as on SYCL.
  Nothing of the Tufty OS is in the window, so this is no worse than the
  SYCL badge.
* Crop clips the picker's frame line and title band by 1..3 rows. Cosmetic.
* Untested on hardware, like every Tufty build so far (snouty-run.md
  section 6 lists the bring-up checks; the hello UF2 isolates them).
