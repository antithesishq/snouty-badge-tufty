# Cart changes for the Tufty

The carts come from the `snouty-badge` submodule. That submodule tracks a
**`tufty` branch**, which is upstream `main` plus any Tufty-only cart
changes. `snouty-badge` main is never modified from here.

| Commit on `tufty` | What |
|---|---|
| cfe3046 | snouty-reflections: `tufty20` variant (full15's scene at 20 fps; docs/ports/snouty-reflections.md) |
| 9cbf968 | `-Dbadge=tufty`: Tufty button names on screen (demosnout, snoutenstein, snouty-bugs) and a clock-seeded snouty-maze (below) |
| c77fd61 | `-Dbadge=tufty` for snouty-flyover and snouty-genesis: Tufty button names on screen, genesis debug overlay off at boot (below) |

## `-Dbadge=tufty`

The monorepo root build declares `-Dbadge=sycl|tufty` once (default `sycl`).
Our `build.zig` passes `.badge = "tufty"` for every cart in `cart_bin`.
Carts with no control names on screen (snouty-run, snouty-reflections) do
not read it. snouty-flyover and snouty-genesis add it to the build_options
module they already had (snouty-bugs needed one added). With `sycl`, the option never reaches a cart's `build_options`,
so the SYCL build stays the same. Checked for snouty-run, demosnout,
snoutenstein, snouty-reflections, snouty-maze and snouty-bugs at 9cbf968
against cfe3046: the loadable bytes (`objcopy -O binary`) and every
non-debug ELF section are byte-identical, and so are the .wasm code and data
sections. Only DWARF moves with the source lines, so the UF2 differs only
in the ELF header's `e_shoff`. snouty-run and snouty-reflections are
identical down to the ELF, UF2 and wasm.

The same check for c77fd61 against 9cbf968, on snouty-flyover (RAM and
XIP), snouty-genesis (XIP), and the carts that share lib/hint.zig with
genesis, snouty-boy, snouty-gear and snouty-lynx (RAM and XIP each): the
`objcopy -O binary` images and every non-debug ELF section are
byte-identical, and so are the .wasm code and data sections. The symbol
addresses are the same; only the debug sections and some anonymous symbol
names (`__anon_NNNN`) move. Every XIP UF2 is byte-identical; the RAM UF2s
differ only in the ELF header's `e_shoff`, as above.

lib/hint.zig (the emulator hints shared by Boy, Gear, Genesis and Lynx)
keeps its SYCL constants. It gains a `Strings` set (`hint.sycl`,
`hint.tufty_genesis`) with `resume_line_in` and
`Overlay.update_and_draw_line`. Only genesis's Tufty build references
them, so the other carts' output is unchanged.

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
| snouty-flyover | district captions (y 119) | `B: send a packet`, `B: collect garbage`, `B: shuffle the band`, `B: insert a key`, `B: rehash the table`, `B: push a frame`, `B: burst the pipe` | the same with `C:` (world.zig swaps the leading `B:` at comptime) |
| snouty-genesis | splash, first 3 s of play | `Hold Select: menu` | `Hold UP+DOWN: menu` (18 columns) |
| | menu, Resume row's bottom line | `Left/Right: rewind` (`Rewind: no history` unchanged) | `A/B: rewind` |
| | menu footer | `B: back to game` | `A+B: back to game` |
| | menu, About | `B: back` | `A+B: back` |
| | menu, Buttons row (six layouts) | `Btns B=B A=C S=A` ... | `Btns AB=B C=C UD=A` ... (badge B = A+B, badge A = C, the Select tap = a short UP+DOWN hold; 18 columns, the panel's width) |
| | ROM picker keys | `A: play`, `B: test ROM` | `C: play`, `A+B: test` |
| | no-ROM help | `A: run test ROM`; `Copy a .gen, .md or .bin file to the SYCLBADGE drive, eject, restart.` | `C: run test ROM`; `Build with -Dgenesis_rom=FILE (.gen, .md or .bin), flash the UF2.` (4 lines either way) |
| | debug overlay | on at boot | off at boot (the menu's `Debug overlay` row still turns it on) |

Before and after, as badge-bench frames (SYCL left, Tufty right):
[snoutenstein title + pause](ports/tufty-labels-snoutenstein.png),
[snouty-bugs title + pause, demosnout picker](ports/tufty-labels-bugs-demosnout.png),
[snouty-flyover captions](ports/tufty-labels-flyover.png) (frames 50 and
100 of the attract run),
[snouty-genesis splash, play hint, menu, About](ports/tufty-labels-genesis.png)
(Miniplanets from the drive; frames 20, 45, 85 and 115 of
`--press SELECT:60-95 --press UP:100-101 --press A:106-107`; the SYCL
frame 45 also shows the debug overlay).

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
