# Cart changes for the Tufty

The carts come from the `snouty-badge` submodule. That submodule tracks a
**`tufty` branch**, which is upstream `main` plus any Tufty-only cart
changes. `snouty-badge` main is never modified from here.

| Commit on `tufty` | What |
|---|---|
| cfe3046 | snouty-reflections: `tufty20` variant (full15's scene at 20 fps; docs/ports/snouty-reflections.md) |
| 9cbf968 | `-Dbadge=tufty`: Tufty button names on screen (demosnout, snoutenstein, snouty-bugs) and a clock-seeded snouty-maze (below) |
| ddd04fc | snouty-zero: with `-Dbadge=tufty` the title also takes A (the Tufty's C), and the PRESS cards say `PRESS C` (docs/ports/snouty-zero.md) |

## `-Dbadge=tufty`

The monorepo root build declares `-Dbadge=sycl|tufty` once (default `sycl`).
Our `build.zig` passes `.badge = "tufty"` for every cart in `cart_bin`.
Carts with no control names on screen (snouty-run, snouty-reflections) do
not read it. With `sycl`, the option never reaches a cart's `build_options`,
so the SYCL build stays the same. Checked for snouty-run, demosnout,
snoutenstein, snouty-reflections, snouty-maze and snouty-bugs at 9cbf968
against cfe3046: the loadable bytes (`objcopy -O binary`) and every
non-debug ELF section are byte-identical, and so are the .wasm code and data
sections. Only DWARF moves with the source lines, so the UF2 differs only
in the ELF header's `e_shoff`. snouty-run and snouty-reflections are
identical down to the ELF, UF2 and wasm.

On-screen strings, SYCL -> Tufty (they follow the maps in `ports/*.md`):

| Cart | Screen | SYCL | Tufty |
|---|---|---|---|
| demosnout | picker hint | `A JUMP  B/SELECT CLOSE` | `A JUMP  B/C CLOSE` |
| snoutenstein | title | `PRESS A` | `PRESS C` |
| | | `SELECT: SOUND ON/OFF` (y 106) | `UP+DN: SOUND ON/OFF` (y 100) |
| | | `B: E1M1  START: TEST` (y 118) | `A+B: E1M1` (y 109), `HOLD UP+DN: TEST` (y 118) |
| | death | `HOLD B TO REWIND` | `HOLD A+B: REWIND` |
| | level clear, victory | `PRESS A` | `PRESS C` |
| | pause (keys) | `UP/DOWN`, `LEFT/RIGHT`, `A`, `SELECT`, `HOLD B`, `BUMP DOOR`, `START` | `UP/DOWN`, `DOUBLE UP` (AUTO), `A/B`, `C`, `TAP UP+DN`, `HOLD A+B`, `BUMP DOOR`, `HOLD UP+DN`. One row more, so the panel is y 8..103 and its rows start at y 24 |
| snouty-bugs | title | `A PLAY`, `B HARDCORE` | `C PLAY`, `A+B HARDCORE` |
| | pause (keys) | `JOYSTICK`, `HOLD A`, `HOLD B`, `START` | `A/B UP/DN`, `TAP C`, `HOLD A+B`, `UP+DOWN`, with the columns at x 16/96 (were 20/92) |
| snouty-zero | title, results, Grand Prix standings | `PRESS START` | `PRESS C`; the title also takes A (it took only Start; the results and standings already took A) |

snouty-zero (ddd04fc against 9cbf968, `-Dcart=snouty-zero -Dcart-mode=xip`):
the SYCL XIP ELF's loadable bytes, every non-debug section and its UF2 are
byte-identical, and so are the .wasm code and data sections. The Tufty
build's `.text` is 4 bytes shorter.

Before and after, as badge-bench frames (SYCL left, Tufty right):
[snoutenstein title + pause](ports/tufty-labels-snoutenstein.png),
[snouty-bugs title + pause, demosnout picker](ports/tufty-labels-bugs-demosnout.png).

**snouty-maze seed.** `cart.rand()` reads 0x4006000C, which on the RP2350
is ACCESSCTRL, not the ROSC. It is always 0, so every boot walked the same
mazes ([ports/snouty-maze.md](ports/snouty-maze.md) section 8). The Tufty
badge build seeds with `cart.rand() ^ mix(micros_since_boot())` in
`start()` (murmur3 finaliser). In the arcade that is the moment someone
picks the cart. It also xors the mixed clock into the rng state once, at
the first button press. So in a single-cart build that boots straight into
the maze, the first maze is fixed and the ones after it are not. Wasm
builds are unchanged, so `preview.mjs --seed` still reproduces runs. No
other cart calls `cart.rand()`. snouty-bugs and snoutenstein seed each
game from `micros_since_boot()` at game start, which already varies.

## Making a cart change

```sh
cd snouty-badge            # on branch tufty
# edit carts/<cart>/..., run the cart's own tests
git commit -am "<cart>: ..."
cd .. && git add snouty-badge && git commit -m "Pin snouty-badge tufty at <sha>"
```

## Pulling new upstream cart work

```sh
cd snouty-badge
git fetch origin && git merge origin/main      # resolve conflicts like any merge
cd .. && zig build && zig build test           # then commit the new pin
git add snouty-badge && git commit -m "Sync carts with snouty-badge main"
```

## Publishing

The `tufty` branch currently lives only in this repo's submodule clone
(`.git/modules/snouty-badge`). A fresh `git clone --recursive` elsewhere
needs it on GitHub. Push it once the snouty-tufty remote exists:

```sh
git -C snouty-badge push origin tufty
```
