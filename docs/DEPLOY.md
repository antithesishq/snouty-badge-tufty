# Deploying to the Tufty badge

The badge runs Supabase's MicroPython build. Our firmware replaces that
firmware, but only within the first 2 MB of flash, which is the
MicroPython firmware slot. The badge's apps and files live above that, in
a ROMFS at 0x10200000 and a FAT partition after it. They stay untouched,
so putting the original firmware back restores the stock badge with all
its files.

Everything below is from a Mac. Install picotool once:

```sh
brew install picotool
```

## 0. Back up first (once, before flashing anything)

1. Plug the badge in with a data-capable USB-C cable.
2. **Files.** Double-tap RESET. A disk mounts. It is probably `Tufty2350`,
   but the Supabase build may use another name. Copy all of it:
   ```sh
   mkdir -p ~/supabase-badge-backup && cp -R /Volumes/<DISK>/ ~/supabase-badge-backup/files/
   ```
   Then eject the disk.
3. **BOOTSEL.** Hold BOOT (HOME), tap RESET, then release BOOT. A disk
   named `RP2350` mounts. That is the chip's bootloader, so the badge
   cannot be bricked this way.
4. **What is it?** Paste this output back into the session. It confirms the
   board, the pins, and whether there is a partition table:
   ```sh
   picotool info -a  > ~/supabase-badge-backup/info.txt
   picotool partition info >> ~/supabase-badge-backup/info.txt
   ```
5. **Full flash image.** This takes a minute or two (16 MB):
   ```sh
   picotool save -a ~/supabase-badge-backup/full-flash.bin
   picotool save -r 0x10000000 0x10200000 ~/supabase-badge-backup/firmware-2mb.uf2
   ```
   `full-flash.bin` restores the badge exactly. `firmware-2mb.uf2` puts back
   only Supabase's firmware and leaves the files alone.

## 1. Get a UF2 from the VM

```sh
scp animated-badge.exe.xyz:snouty-tufty/zig-out/firmware/snouty-tufty-hello.uf2 .
scp -r animated-badge.exe.xyz:snouty-tufty/dist/control .   # Pimoroni's own demo builds
```

Or build it locally: `git clone --recursive` this repo, then run
`zig build` (the same pinned Zig as snouty-badge).

## 2. Flash

Enter BOOTSEL (hold BOOT, tap RESET), then do either of these:

* drag the `.uf2` onto the `RP2350` disk, or
* run `picotool load -x snouty-tufty-hello.uf2`

The badge reboots into the new firmware. In our firmware, holding HOME for
a second reboots straight into BOOTSEL for the next flash.

Try the order **control first, ours second**. If Pimoroni's demo works and
ours does not, the bug is ours. If neither works, the Supabase board
differs from a stock Tufty, and `info.txt` should say how.

## 3. Restore Supabase's badge

Enter BOOTSEL, then do either of these:

* drag `firmware-2mb.uf2` onto `RP2350`. This puts back the Supabase
  firmware with your files untouched.
* run `picotool load ~/supabase-badge-backup/full-flash.bin -o 0x10000000 && picotool reboot`.
  This writes back the exact original flash.

If both backups are lost, Pimoroni's stock firmware works too. It is at
<https://github.com/pimoroni/tufty2350/releases/latest>: the plain `.uf2`
keeps the files, and `with-filesystem` resets them. You would lose any
Supabase-specific firmware changes.
