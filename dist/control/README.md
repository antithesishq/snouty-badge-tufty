# Control firmware: Pimoroni's own Tufty demos

These two UF2s are a known-good baseline. Flash one before our Zig firmware.
If it works and ours does not, the bug is ours. If neither works, check the
badge hardware.

| File | Demo | Size | Flash range written |
|---|---|---|---|
| `pimoroni-buttons-tufty.uf2` | `buttons` (shows button input) | 162,816 B (318 blocks, 81,408 B payload) | 0x10000000..0x10013e00 |
| `pimoroni-text-tufty.uf2` | `text` (animated word wrap) | 143,872 B (281 blocks, 71,936 B payload) | 0x10000000..0x10011900 |

## Where they came from

* Source: <https://github.com/pimoroni/badgeware-cpp> at commit
  `7d1ef0882c6e9dcf374542528f6f211e287b5afb` ("Initial Commit"). Its
  submodule `lib/picovector` (<https://github.com/pimoroni/picovector>,
  branch `no-bindings`) is at `2fa6f81e362d2fb3ededbc52e44a8fe618f9bc1a`.
  The code is unmodified.
* License: MIT, Copyright (c) 2026 Pimoroni Ltd (see `LICENSE` in that repo).
* Pico SDK 2.2.0 (<https://github.com/raspberrypi/pico-sdk>, tinyusb
  submodule only). picotool 2.2.0 was built from source by the SDK.
* Toolchain: arm-none-eabi-gcc 13.2, CMake 3.28, Ninja, `Release` build.
* Build:
  ```sh
  export PICO_SDK_PATH=/path/to/pico-sdk        # 2.2.0
  cmake -S badgeware-cpp -B build/tufty -G Ninja -DBADGE_BOARD=tufty -DCMAKE_BUILD_TYPE=Release
  cmake --build build/tufty -j2 --target buttons text
  picotool uf2 convert build/tufty/demos/buttons/buttons.elf pimoroni-buttons-tufty.uf2 --family rp2350-arm-s
  picotool uf2 convert build/tufty/demos/text/text.elf       pimoroni-text-tufty.uf2    --family rp2350-arm-s
  ```
  `tools/build-control.sh [WORKDIR]` does all of this from scratch: shallow
  clones at the pinned versions, build, re-pack, range check, and copy here.
  Two runs of the script made byte-identical files. A build on another day
  differs only in the embedded build date.

### Why the re-pack

The SDK makes its own `.uf2` with `--abs-block` because the Tufty board
header sets `PICO_RP2350_A2_SUPPORTED=1`. That puts one extra block first:
the RP2350-E10 workaround, family `absolute` (0xe48bff57), aimed at
**0x10ffff00**. That address is the last page of the 16 MB flash, inside the
badge's FAT filesystem. A3 and later bootroms skip that block. On A2 silicon
it may be written to flash, so we dropped it. We converted the same ELF
again without `--abs-block`. The flash pages match the SDK's UF2 byte for
byte. Only the absolute block and the block numbering differ.

## Address range check

Both files pass. Every block has family **0xe48bff59 (RP2350 ARM Secure)**,
and every block sits inside 0x10000000..0x10200000, the first 2 MB, which is
the MicroPython firmware slot. Nothing touches the ROMFS (0x10200000) or the
FAT partition above it. The firmware never writes flash at run time: there
are no `flash_range_*` calls in the runtime or the board code.

`picotool info -a` on both: target chip RP2350, image type ARM Secure,
pico_board `pimoroni_tufty2350`, SDK 2.2.0, binary start 0x10000000. The
binary ends at 0x10013d68 (buttons) and 0x10011804 (text). Both have USB
stdio (CDC serial), which prints nothing unless the firmware panics.

## What you should see

Both demos run in LORES mode: a 160x120 framebuffer, pixel-doubled to fill
the 320x240 screen. Expect chunky pixels in the small "Sins" pixel font.

### buttons

* Black screen. "press a button" sits top left in grey-blue text.
* Six dim coloured circles, one per button, each with a white letter:
  * **H** (orange) at top centre
  * **U** (amber) and **D** (green) on the right, U above D
  * **A** (light blue), **B** (violet), **C** (magenta) along the bottom
    left

  The demo asks for purple on H, but its hue of 280 wraps in the 0-255
  hue byte to 24, which gives orange. H and U therefore look almost the
  same colour.
* Hold a button and its circle lights up bright, with a pulsing radius and
  a coloured outline. Each new press sends out an expanding ring that fades
  over about 0.7 s.
* The five front buttons and HOME/BOOT each light their own pad. In this
  demo HOME is just another pad: it does **not** reboot to BOOTSEL.

### text

* Black screen with green text: a pirate-skull verse, word-wrapped inside a
  thin grey-blue box.
* The box width swings back and forth, a sine with a period of about 3 s,
  and the text re-wraps every frame. This shows continuous redraw.
* The demo ignores the buttons. HOME does nothing here either.

## Buttons that work in both

* **Re-flash / BOOTSEL:** hold HOME (BOOT), tap RESET, release HOME. The
  `RP2350` disk mounts. Neither demo reboots to BOOTSEL by itself.
* **Power button (RESET):** a short press resets the badge and restarts the
  demo. Holding it at boot runs a sweep on the four rear case LEDs, then the
  badge sleeps. A front button press wakes it. Hold UP+DOWN as well to enter
  shipping mode instead of sleep.
