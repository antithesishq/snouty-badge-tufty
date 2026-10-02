# snouty-badge-tufty

The Snouty carts on the Supabase Select 2026 badge, a Pimoroni Badgeware
Tufty 2350 (RP2350B, 320x240 LCD, five buttons).

Caution! This repo is a fun side project and I make no guarantees about performance or stability. These are working great on my hardware, but flash at your own risk!

**To put the carts on your badge, follow [docs/DEPLOY.md](docs/DEPLOY.md).**
Back up your badge first: its Supabase firmware is not part of this repo.

The carts come from [snouty-badge](https://github.com/antithesishq/snouty-badge),
which is a git submodule here. This repo adds a small Zig "Tufty OS" that
speaks the SYCL badge's cart ABI. The same RP2350-family cart builds
therefore run on core 1 with the Tufty's screen and buttons.

* [PLAN.md](PLAN.md): the approach and the milestones
* [docs/DEPLOY.md](docs/DEPLOY.md): **start here**: back up your badge, build, install (dual boot beside Supabase, arcade only, or Genesis), controls, restore
* [docs/ARCADE.md](docs/ARCADE.md): the arcade UF2 (every cart behind a
  boot menu), how to add a cart, the flash budget
* [docs/DUALBOOT.md](docs/DUALBOOT.md): the arcade as a dual boot beside the
  badge's own Supabase MicroPython firmware, with its launcher app
  (`supabase-app/`)
* [docs/POWER.md](docs/POWER.md): hold RESET to power off, any button to wake
* [docs/ports/](docs/ports/README.md): per-cart port notes and button maps
* [docs/CARTS.md](docs/CARTS.md): Tufty-only cart changes (the submodule's `tufty` branch)

```sh
git clone --recursive https://github.com/antithesishq/snouty-badge-tufty
zig build            # zig-out/firmware/*.uf2
zig build test       # host unit tests
zig build menu-png   # docs/arcade-menu.png, the menu as the panel shows it
```

The main outputs:

* `snouty-tufty-arcade.uf2`: all carts with a menu (M2)
* `snouty-tufty-arcade-supabase.uf2`: the same arcade beside MicroPython;
  it writes only the free flash gap 0x1014F000..0x10200000
* `snouty-tufty-<cart>.uf2`: one cart, picked with `-Dcart=` (M1)
* `snouty-tufty-hello.uf2`: the M0 test screen

Each cart-host UF2 has a `.flash.txt` report next to it.

`reference/badgeware-cpp-tufty/` holds Pimoroni's MIT-licensed Tufty
display driver (badgeware-cpp 7d1ef08), which is the hardware reference
for our driver.
