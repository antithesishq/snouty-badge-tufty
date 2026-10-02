# snouty-tufty

The Snouty carts on the Supabase Select 2026 badge, a Pimoroni Badgeware
Tufty 2350 (RP2350B, 320x240 LCD, five buttons).

The carts come from [snouty-badge](https://github.com/antithesishq/snouty-badge),
which is a git submodule here. This repo adds a small Zig "Tufty OS" that
speaks the SYCL badge's cart ABI. The same RP2350-family cart builds
therefore run on core 1 with the Tufty's screen and buttons.

* [PLAN.md](PLAN.md): the approach and the milestones
* [docs/DEPLOY.md](docs/DEPLOY.md): back up the badge, flash, restore
* [docs/ARCADE.md](docs/ARCADE.md): the arcade UF2 (every cart behind a
  boot menu), how to add a cart, the flash budget
* [docs/ports/](docs/ports/README.md): per-cart port notes and button maps

```sh
git clone --recursive <this repo>
zig build            # zig-out/firmware/*.uf2
zig build test       # host unit tests
zig build menu-png   # docs/arcade-menu.png, the menu as the panel shows it
```

The main outputs:

* `snouty-tufty-arcade.uf2`: all carts with a menu (M2)
* `snouty-tufty-<cart>.uf2`: one cart, picked with `-Dcart=` (M1)
* `snouty-tufty-hello.uf2`: the M0 test screen

Each cart-host UF2 has a `.flash.txt` report next to it.

`reference/badgeware-cpp-tufty/` holds Pimoroni's MIT-licensed Tufty
display driver (badgeware-cpp 7d1ef08), which is the hardware reference
for our driver.
