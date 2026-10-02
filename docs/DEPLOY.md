# Putting the Snouty carts on your badge

This guide is for a Supabase Select 2026 badge, which is a Pimoroni
Badgeware Tufty 2350 running Supabase's MicroPython firmware. It may work
on a stock Tufty 2350 too. Your badge's own firmware, apps and files are
**not** part of this repo. Step 1 backs up your copy, and only you keep it.
Don't commit or share that backup: the Supabase firmware isn't ours to
distribute.

There are three ways to install. Pick one in step 3.

| Install | What you get | Supabase badge |
|---|---|---|
| **A. Dual boot** (recommended) | The arcade as an app in the Supabase launcher: 7 carts, and a menu row back to Supabase | kept; it still boots by default |
| **B. Arcade only** | 8 carts behind a boot menu, Snouty Zero included | replaced, until you restore it |
| **C. Genesis** | The Genesis emulator with your own ROM (Sonic works great) | replaced, until you restore it |

Every install leaves your badge's apps and files alone. The Tufty's flash
is laid out like this: Supabase's firmware is in the first 2 MB, a ROMFS
sits at 0x10200000, and the drive with your files comes after it. B and C
write only inside the first 2 MB. A writes only the unused gap
0x1014F000..0x10200000 between the firmware and the ROMFS.

## 0. What you need

* The badge and a **data-capable** USB-C cable. Some cables only charge.
* [picotool](https://github.com/raspberrypi/picotool). On a Mac:
  `brew install picotool`.
* To build: git and the Zig version pinned in `build.zig.zon`
  (`0.17.0-dev.1936+5a625d5f3`, the same as snouty-badge).

The badge's buttons, as this guide names them:

* **A, B, C** are on the bottom edge, and **UP, DOWN** on the right of the
  screen.
* **HOME / BOOT** is on the back, and so are **RESET** and the rest.
* **BOOTSEL** means: hold HOME, tap RESET, release HOME. A disk named
  `RP2350` mounts. That is the chip's own ROM bootloader, so you can always
  get back to it, whatever is in flash.

## 1. Back up your badge (once, before anything else)

1. **Files.** Double-tap RESET. The badge's drive mounts; on the Supabase
   badge it is `Tufty2350` or similar (`ls /Volumes`). Copy all of it,
   then eject:
   ```sh
   mkdir -p ~/supabase-badge-backup
   cp -R /Volumes/<DRIVE>/ ~/supabase-badge-backup/files/
   ```
2. **Firmware and flash.** Enter BOOTSEL, then:
   ```sh
   picotool info -a > ~/supabase-badge-backup/info.txt
   picotool save -r 0x10000000 0x10200000 ~/supabase-badge-backup/firmware-2mb.uf2
   picotool save -a ~/supabase-badge-backup/full-flash.bin     # 16 MB, a minute or two
   ```
   * `firmware-2mb.uf2` puts back Supabase's firmware and leaves your
     files alone. This is the one you normally need.
   * `full-flash.bin` is the whole chip, exactly as it was.
   * `info.txt` records the firmware's size. The dual boot needs the
     "binary end" to be at or below `0x1014F000`. On the Supabase badge
     (MicroPython `bw-1.29.0`) it is `0x1014e220`.

Check that the backup worked before going on: `ls -la
~/supabase-badge-backup` should show `full-flash.bin` at exactly
16777216 bytes, and `firmware-2mb.uf2` at about 4 MB.

## 2. Build

```sh
git clone --recursive https://github.com/antithesishq/snouty-badge-tufty
cd snouty-badge-tufty
tools/stage-dist.sh                 # everything, into dist/firmware/
# or: tools/stage-dist.sh path/to/your-rom.bin   (the Genesis ROM for install C)
```

`dist/firmware/` then holds:

* `snouty-tufty-arcade-supabase.uf2` and `snouty_arcade/`, for install A
* `snouty-tufty-arcade.uf2`, for install B
* `snouty-tufty-genesis.uf2`, for install C
* `snouty-tufty-<cart>.uf2`, one cart without the menu
* `snouty-tufty-hello.uf2`, a test screen for the panel and the buttons

You can also run single steps: `zig build` (the arcade), `zig build
supabase` (the dual boot), `zig build -Dcart=<cart>`. Outputs land in
`zig-out/firmware/`, each with a `.flash.txt` that lists exactly which
flash range the UF2 writes.

## 3A. Dual boot: the arcade inside the Supabase launcher

1. **Start from Supabase's firmware.** If you flashed install B or C
   earlier, enter BOOTSEL and put it back first:
   ```sh
   picotool load -x ~/supabase-badge-backup/firmware-2mb.uf2
   ```
2. **Check the firmware end.** In BOOTSEL, run `picotool info -a`. The
   "binary end" must be at or below **0x1014F000**. If it is higher (for
   example after a Supabase or Pimoroni firmware update), stop here: this
   UF2 would overwrite the end of it.
3. **Flash.** Still in BOOTSEL:
   ```sh
   picotool load snouty-tufty-arcade-supabase.uf2 && picotool reboot
   ```
   Don't add `-o`: the UF2 already carries its addresses. The badge boots
   Supabase as usual.
4. **Install the launcher app.** Double-tap RESET, copy the app into the
   drive's `apps/` folder, eject, then press RESET:
   ```sh
   cp -R snouty_arcade "/Volumes/<DRIVE>/apps/"
   # apps/snouty_arcade/__init__.py, snouty_dualboot.py, icon.png
   ```
5. **Play.** In the Supabase launcher, pick **Snouty Arcade** and press B.
   The arcade appears about a second later. Its last row, **SUPABASE
   BADGE**, takes you back.

To update the arcade, repeat step 3. To remove it, delete
`apps/snouty_arcade` from the drive; the gap it used is not used by
anything else. [DUALBOOT.md](DUALBOOT.md) explains how the launch works
and what each failure looks like.

## 3B. Arcade only

Enter BOOTSEL, then:

```sh
picotool load -x snouty-tufty-arcade.uf2
```

The badge boots straight into the menu.

## 3C. Genesis with your own ROM

Build with a ROM you dumped yourself: `tools/stage-dist.sh your-rom.bin`,
or `zig build -Dcart=snouty-genesis -Dgenesis_rom=your-rom.bin`. Without a
ROM, the UF2 carries the open homebrew game Miniplanets. ROMs are never
committed to this repo. Then enter BOOTSEL and run:

```sh
picotool load -x snouty-tufty-genesis.uf2
```

## 4. Playing

The arcade menu works like this:

* UP/DOWN choose a cart, and C plays it.
* In a cart, a short HOME press goes back to the menu, and holding HOME
  for 1 s reboots into BOOTSEL. That is handy for the next flash.
* The single-cart UF2s restart the cart on a short HOME press instead.
* **Power off:** hold RESET until the rear LEDs have swept on and faded
  out (about 2 s). Any of A, B, C, UP, DOWN or RESET turns it back on.
  Hold UP + DOWN as well for the deepest off, which only RESET wakes. See
  [POWER.md](POWER.md).

Each cart's on-screen hints use the Tufty's button names. The main
controls:

| Cart | Controls |
|---|---|
| Snouty Run | C jump |
| Demosnout | A skip part, B hold, C part picker |
| Snoutenstein | A/B turn, UP/DOWN walk, C fire, double-tap UP to autowalk, hold A+B to rewind, UP+DOWN: tap for weapon, hold to pause |
| Snouty Bughunt | C turns autofire on (and starts), A/B/UP/DOWN fly, fly into crates for weapons and extras, hold A+B to rewind, UP+DOWN pause |
| Snouty Reflections | A/B orbit, UP/DOWN height, C freeze (path tracing), A+B lighting preset, UP+DOWN dither |
| Snouty Maze | A/B turn, UP/DOWN step, tap C to skip, hold C for the name strip |
| Snouty Flyover | A/B bank, UP climb, DOWN dive, C district verb, A+B boost, UP+DOWN: tap to skip, hold for autopilot |
| Snouty Zero (B only) | C throttle (latches on), A/B steer, UP boost, DOWN brake, hold A+B to rewind, UP+DOWN pause |
| Genesis (C) | A/B left/right, C jump, UP/DOWN, A+B is Genesis B, tap UP+DOWN for Start, hold UP+DOWN about 1 s for the emulator menu (rewind with A/B there) |

The per-cart details are in [ports/](ports/README.md).

## 5. Back to the Supabase badge

Enter BOOTSEL, then use one of these:

* `picotool load -x ~/supabase-badge-backup/firmware-2mb.uf2` puts back
  Supabase's firmware with your files untouched.
* `picotool load ~/supabase-badge-backup/full-flash.bin -o 0x10000000 &&
  picotool reboot` writes back the exact original flash.

If you have lost both backups, Pimoroni's stock Tufty firmware also works:
<https://github.com/pimoroni/tufty2350/releases/latest>. Its plain `.uf2`
keeps your files, and `with-filesystem` resets them. You would lose
whatever Supabase changed in their build.

## Troubleshooting

* **Black screen or no backlight after flashing B or C.** Flash
  `snouty-tufty-hello.uf2`. Its test screen shows colour bars, a
  "TOP LEFT" marker and the button states, and it boots at 250 MHz.
  `snouty-tufty-hello-150.uf2` boots at 150 MHz, which rules out the
  clock. Pimoroni's own demo builds in `dist/control/` rule out our code
  entirely.
* **Dual boot: the `RP2350` drive appears when you launch.** The bootrom
  refused the launch. Press RESET. If you get a black screen instead, the
  arcade crashed; press RESET. If you land back in Supabase, the app shows
  an error code ([DUALBOOT.md](DUALBOOT.md) lists them).
* **Genesis or Zero crash or show garbled graphics.** These two run from
  flash at 250 MHz, and flash read timing is their main risk. Please open
  an issue.
