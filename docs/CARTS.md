# Cart changes for the Tufty

The carts come from the `snouty-badge` submodule. That submodule tracks a
**`tufty` branch**, which is upstream `main` plus any Tufty-only cart
changes. `snouty-badge` main is never modified from here.

| Commit on `tufty` | What |
|---|---|
| cfe3046 | snouty-reflections: `tufty20` variant (full15's scene at 20 fps; docs/ports/snouty-reflections.md) |

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
