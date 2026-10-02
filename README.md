# snouty-tufty

The Snouty carts on the Supabase Select 2026 badge, a Pimoroni Badgeware
Tufty 2350 (RP2350B, 320x240 LCD, five buttons).

The carts come from [snouty-badge](https://github.com/antithesishq/snouty-badge),
which is a git submodule here. This repo adds a small Zig "Tufty OS" that
speaks the SYCL badge's cart ABI. The same RP2350-family cart builds
therefore run on core 1 with the Tufty's screen and buttons.

* [PLAN.md](PLAN.md): the approach and the milestones
* [docs/DEPLOY.md](docs/DEPLOY.md): back up the badge, flash, restore

```sh
git clone --recursive <this repo>
zig build            # zig-out/firmware/*.uf2
```

`reference/badgeware-cpp-tufty/` holds Pimoroni's MIT-licensed Tufty
display driver (badgeware-cpp 7d1ef08), which is the hardware reference
for our driver.
