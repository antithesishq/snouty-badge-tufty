#!/usr/bin/env bash
# Build every deliverable and copy it to dist/firmware/ (gitignored), the
# folder the badge owner fetches with:
#   scp -r 'animated-badge.exe.xyz:snouty-tufty/dist/firmware/*' .
#
#   tools/stage-dist.sh [GENESIS_ROM]
#
# GENESIS_ROM (optional): a Genesis ROM file for snouty-tufty-genesis.uf2.
# Without it the genesis UF2 carries the cart's open Miniplanets ROM. Never
# commit a ROM; dist/firmware/ is ignored by git.
set -euo pipefail
cd "$(dirname "$0")/.."
out=dist/firmware
mkdir -p "$out"

# Default build: the arcade (RAM carts + any XIP cart) and the hello screens.
zig build
cp zig-out/firmware/snouty-tufty-arcade.uf2 zig-out/firmware/snouty-tufty-hello*.uf2 "$out/"

# The dual boot beside Supabase's MicroPython, and its launcher app.
zig build supabase
cp zig-out/firmware/snouty-tufty-arcade-supabase.uf2 "$out/"
rm -rf "$out/snouty_arcade" && cp -r supabase-app/snouty_arcade "$out/"

# One UF2 per cart. The carts table's names, from the build's own error text.
carts=$(sed -n 's/^    \.{ \.name = "\([a-z0-9-]*\)".*/\1/p' build.zig)
for c in $carts; do
    [ "$c" = snouty-genesis ] && continue
    zig build -Dcart="$c"
    cp "zig-out/firmware/snouty-tufty-$c.uf2" "$out/"
done

# Genesis last, with the ROM if given.
if [ $# -ge 1 ]; then
    zig build -Dcart=snouty-genesis -Dgenesis_rom="$1"
else
    zig build -Dcart=snouty-genesis
fi
cp zig-out/firmware/snouty-tufty-genesis.uf2 "$out/"

ls -la "$out"
