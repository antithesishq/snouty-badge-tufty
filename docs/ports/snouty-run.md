# snouty-run on the Tufty

The first hardware test for the Tufty OS (M1). Snouty runs across Green Hill
Zone forever, and one button jumps. The cart is the unmodified RAM-mode build
from `snouty-badge/carts/snouty-run` (submodule at 48c0d18). Our build runs the
submodule's own `build.zig` for it, and the Tufty OS embeds the cart's
loadable bytes.

## 1. Build and flash

```sh
zig build                     # -Dcart=snouty-run -Dscale=fit are the defaults
# -> zig-out/firmware/snouty-tufty-snouty-run.uf2   (Tufty OS + cart, 250 MHz)
#    zig-out/firmware/snouty-tufty-hello.uf2        (M0 test screen, 250 MHz)
#    zig-out/firmware/snouty-tufty-hello-150.uf2    (M0 test screen, 150 MHz)
#    zig-out/firmware/cart/snouty.{elf,bin}         (the embedded cart, for inspection)
```

Flash it as in [../DEPLOY.md](../DEPLOY.md): back up first, enter BOOTSEL
(hold HOME, tap RESET), then drop the UF2 on `RP2350`. After that, hold HOME
for 1 s in our firmware to get back to BOOTSEL.

UF2 facts (checked here): 637 blocks, family `0xe48bff59` (RP2350_ARM_S),
targets `0x10000000..0x10027d00` (159 KB). That is far below the
`0x10200000` limit, and there is no `0x10ffff00` absolute-family block. The
IMAGE_DEF block is at `0x10000110` (exe, secure, Arm, RP2350).

## 2. Controls

snouty-run reads one input: `controls.a`, on the press edge (`main.zig`,
`update()`: jump if A is pressed while running). Nothing else is read. The
map follows the split d-pad of [README.md](README.md). C is the action button.

| Tufty | Cart sees | Effect |
|---|---|---|
| **C** | a | **jump** |
| A | left | nothing (not read) |
| B | right | nothing |
| UP | up | nothing |
| DOWN | down | nothing |
| HOME, short press | (OS) | restart the cart from a fresh RAM image |
| HOME, held 1 s | (OS) | reboot into BOOTSEL |

The map has no chords, so nothing is delayed or masked. Every rising bit is
stretched to at least 2 cart presents, so a very quick tap of C still jumps.
The map lives in `src/controls_map.zig` (`snouty_run`). The other carts'
maps use the same data format (direct, chord with `chord_ms`, tap/hold,
pulse stretch).

## 3. Screen

Scale mode **fit** (the default). Cart x is doubled (160 to 320). Cart y is
nearest-neighbour from 128 to 240, so every cart row is drawn 1 or 2 panel
rows tall and no row is lost. `-Dscale=crop` gives an exact 2x with cart rows
0..3 and 124..127 dropped. `-Dscale=native` gives 1:1, centred, with a black
border.

What you should see:

* About 0.3 s after power-on (clock, power rail, 150 ms panel reset, 100 ms
  sleep-out), the backlight comes on at about 90%.
* The Green Hill backdrop (palette-cycling water, upper ~3/4), the
  checkerboard ground, and Snouty running left to right.
* A panel along the bottom: the Iris mark at both ends, "Adrian Hatch" and
  "Antithesis".
* Snouty leaves the right edge, the screen pauses for 1 s, and Snouty comes
  back from the left. Press C while he runs and he jumps.
* 60 fps. The cart asks for vsync at 16.67 ms. The OS paces presents on the
  timer, because TE is not used.

For a reference picture, run badge-bench on `zig-out/firmware/cart/snouty.elf`
with `--png` (section 4). It shows the same frame at 160x128.

If the colours are wrong, the screen is mirrored, or nothing appears, flash
`snouty-tufty-hello.uf2`. Its test screen pins down each of these (section 6).

## 4. Verification done here (no badge)

* `zig build test`: 27 host tests pass. They cover:
  * scaler: the fit row table keeps every row in order; crop and native
    maps; panel windows for full and dirty rects; the SYCL pixel (red in the
    low bits) to panel wire pixel (red in the high bits, big-endian)
    conversion; `fill_column`.
  * controls: direct, chord masking, `chord_ms` delay and tap-through,
    tap/hold on a chord, 2-present pulse stretch, and the SYCL `Controls`
    bit layout.
  * ABI: every IPC block offset (0x15090 controls ... 0x150EC size) pinned
    to os_abi.zig; PresentFlags; cart image validation (magic, version, BSS
    range, Thumb entry inside the image).
  * M0 test pattern and the HOME short/long logic.
* The cart ELF (`zig-out/firmware/cart/snouty.elf`):
  * `.cart_descriptor` is at 0x20035100.
  * Then `.text`, `.ARM.exidx` and `.data` contiguous to 0x2005a724.
  * `.bss` is 0x2005a728..0x2005a758.
  * The entry `_start` is 0x20035115.
  * `cart.bin` (153,124 bytes) starts with `41ca c154 0126 c154`: CART_MAGIC,
    then V1.
* The Tufty OS ELF:
  * The embedded blob is found byte-identical in the UF2 payload at flash
    0x10001e68.
  * OS RAM: `.bss` is 0x20000000..0x20000918. The initial SP is 0x20020000.
    The linker region is cut to 128 KB, so nothing of ours can land in
    0x20020000..0x20080000.
* badge-bench, 300 frames, with C/A pressed at frame 120:
  * Runs normally.
  * Modelled busy time at 150 MHz: mean 6.43 ms, worst 7.79 ms
    (1.17 M cycles).
  * At 250 MHz that is about 3.9 ms mean and 4.7 ms worst on core 1.
* Present cost (computed):
  * 320x240x2 = 153,600 bytes per frame.
  * PIO clock 250/6 = 41.7 MHz. The PIO takes 2 cycles per byte, so the bus
    moves 20.8 MB/s and a frame takes about 7.4 ms on core 0.
  * The cart draws the other buffer meanwhile (`no_copy_full_frame`), so
    60 fps has about 9 ms of slack.

## 5. How the OS runs the cart (M1)

`src/cart_host.zig`:

1. Clocks 250 MHz, power rail, panel, backlight.
2. Validate the embedded image. On failure, a solid-colour screen:
   * red: too large
   * yellow: no descriptor
   * magenta: bad version
   * blue: bad BSS or entry

   On that screen, HOME held 1 s still gives BOOTSEL.
3. Hold core 1 in reset. Abort DMA channels 1..15. Free SIO spinlock 10.
   Zero 0x20020000..0x20080000. Copy the image to 0x20035100. Zero BSS per
   the descriptor. Seed controls, light level (0x800) and battery (0xFFF).
4. `launch_core1`. Core 1 then:
   * masks interrupts
   * clears the NVIC, SysTick and fault state
   * enables DWT CYCCNT (TRCENA)
   * sets FPU lazy stacking and CPACR
   * sets MSP = 0x20080000
   * `bx` to the cart entry

   These are the steps of `sycl-badge/src/os/cart.zig executeCart`.
5. Loop:
   * buttons go through the mapper into `ipc.controls`
   * HOME logic
   * drain the FIFO. `FRAMEBUFFER_READY(_V2)` queues a present, and
     `SYNC_TIME_REQ_CLR` runs the time handshake. Tone, volume and trace are
     accepted and ignored, so the cart never blocks on a full FIFO.
   * When a present is queued and pacing allows, stream the dirty window
     column by column, then send `FRAMEBUFFER_DONE`.

## 6. Untested on hardware: what to check first

In order of likelihood:

1. **Clock path to 250 MHz.**
   * VREG goes to 1.20 V (POWMAN password write, then UNLOCK, as pico-sdk
     `vreg_set_voltage`), then PLL_SYS 1500/6/1.
   * QMI (flash XIP) timing is left exactly as the bootrom set it. That is
     what Pimoroni's pico-sdk build does at 250 MHz.
   * Symptom of a failure: backlight never comes on. Then flash
     `snouty-tufty-hello-150.uf2`. If that works, the 250 MHz path is the
     bug.
2. **PIO1 GPIOBASE = 16.** This is a direct write of `GPIOBASE` before any
   pin mapping. microzig 0.17.7 has no setter, but its pin-index maths reads
   the register. Symptom: backlight on, but the panel stays black or shows
   noise.
3. **Bus timing.**
   * PIO clkdiv 6.0 at 250 MHz (3.5 at 150), which is Pimoroni's formula
     `ceil(2*sys/44 MHz)/2`. The task note said 3.0, but the formula gives
     6.0.
   * WR period 48 ns. WR idles low (side-set applies while `out` stalls),
     which is the same as the reference.
   * CS/DC change only after DMA done + PIO TXSTALL.
4. **Orientation.**
   * MADCTL 0x90 (ROW_ORDER | SCAN_ORDER), CASET 0..239, RASET 0..319, as
     the reference sets them.
   * Each landscape column is streamed top to bottom, x = 0 first.
   * The hello screen's red square + "TOP LEFT" tell which way any mirror
     goes.
5. **Colours.**
   * SYCL pixels keep red in the low 5 bits (the SYCL panel is BGR). The
     scaler swaps r/b and sends RGB565 big-endian, matching the
     reference's `to_rgb565_be` with MADCTL BGR = 0.
   * If red and blue come out swapped, flip it in `scaler.wire_pixel`.
   * If the picture is speckled, the byte order is wrong. The hello grey
     ramp shows this.
6. **Power rail.** GPIO41 is driven high, then a 50 ms wait, before any
   panel access.
7. **Buttons.** All six use internal pull-ups and are active low. HOME is
   GPIO22. Pimoroni's sleep code leaves it floating, which suggests an
   external pull too. Either way it reads low when pressed. Check that a
   short HOME press restarts the cart and does not reboot it.
8. **Core 1 launch.**
   * The microzig bootrom FIFO handshake, then the jump with MSP 0x20080000.
   * If the panel stays black after the backlight comes on, the cart may
     not be presenting. The cart's first act is the SYNC_TIME handshake,
     which the OS answers.
9. **TE not used.** Expect possible tearing. Presents are paced at
   16.67 ms on TIMER0 (1 MHz from clk_ref, as on the SYCL badge).
10. **BOOTSEL reboot.** The bootrom `reboot(BOOTSEL | NO_RETURN, 10 ms)`
    should mount `RP2350`.

Two upstream findings (same behaviour as the SYCL badge, nothing to fix here):

* `platform_cart_ram.zig rand()` reads 0x4006000C bit 16. On RP2350 that
  address is ACCESSCTRL GPIO_NSMASK0, not ROSC (0x400E8000). So `cart.rand()`
  probably returns a constant on both badges.
* The SYCL OS's `abortCartChannels` writes DMA + 0x444, which is the RP2040
  CHAN_ABORT offset. The RP2350 offset is 0x464, and the Tufty OS uses that.
