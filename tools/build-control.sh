#!/usr/bin/env bash
# Build the "control" firmware: Pimoroni's own badgeware-cpp demos for the
# Tufty 2350, so the badge can be checked with native firmware before ours.
#
#   tools/build-control.sh [WORKDIR]     (default WORKDIR: ./build-control)
#
# Clones badgeware-cpp (pinned commit) and the Pico SDK (pinned tag) into
# WORKDIR, builds the chosen demos for -DBADGE_BOARD=tufty, re-packs each ELF
# as a UF2 *without* the RP2350-E10 absolute block (see dist/control/README.md),
# checks every UF2 stays below 0x10200000, and copies them to dist/control/.
#
# Needs: git, cmake >= 3.13, ninja, python3, arm-none-eabi-gcc with newlib and
# libstdc++, and a host C++ compiler (the SDK builds picotool from source).
set -euo pipefail

BADGEWARE_URL=https://github.com/pimoroni/badgeware-cpp
BADGEWARE_COMMIT=7d1ef0882c6e9dcf374542528f6f211e287b5afb   # picovector submodule 2fa6f81
SDK_URL=https://github.com/raspberrypi/pico-sdk
SDK_TAG=2.2.0
DEMOS=(buttons text)
JOBS=${JOBS:-2}

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mkdir -p "${1:-$ROOT/build-control}" && cd "${1:-$ROOT/build-control}" && pwd)
OUT=$ROOT/dist/control

for t in git cmake ninja python3 arm-none-eabi-gcc c++; do
  command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

# --- sources (shallow) ------------------------------------------------------
if [ ! -d "$WORK/badgeware-cpp/.git" ]; then
  git init -q "$WORK/badgeware-cpp"
  git -C "$WORK/badgeware-cpp" remote add origin "$BADGEWARE_URL"
fi
git -C "$WORK/badgeware-cpp" fetch -q --depth 1 origin "$BADGEWARE_COMMIT"
git -C "$WORK/badgeware-cpp" checkout -q --detach "$BADGEWARE_COMMIT"
git -C "$WORK/badgeware-cpp" submodule update -q --init --depth 1

if [ ! -d "$WORK/pico-sdk/.git" ]; then
  git clone -q --depth 1 --branch "$SDK_TAG" "$SDK_URL" "$WORK/pico-sdk"
fi
git -C "$WORK/pico-sdk" submodule update -q --init --depth 1 lib/tinyusb

# --- build ------------------------------------------------------------------
export PICO_SDK_PATH=$WORK/pico-sdk
BUILD=$WORK/badgeware-cpp/build/tufty
cmake -S "$WORK/badgeware-cpp" -B "$BUILD" -G Ninja \
  -DBADGE_BOARD=tufty -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD" -j"$JOBS" --target "${DEMOS[@]}"

PICOTOOL=$BUILD/_deps/picotool-build/picotool
[ -x "$PICOTOOL" ] || PICOTOOL=$(command -v picotool)

# --- re-pack, check, copy ---------------------------------------------------
mkdir -p "$OUT"
for d in "${DEMOS[@]}"; do
  # The SDK's own .uf2 starts with an RP2350-E10 "absolute" block aimed at
  # 0x10ffff00 (last page of the 16 MB flash, inside the FAT area). Convert the
  # ELF again without --abs-block: same pages, nothing outside the image.
  "$PICOTOOL" uf2 convert "$BUILD/demos/$d/$d.elf" "$OUT/pimoroni-$d-tufty.uf2" \
    --family rp2350-arm-s
done

python3 - "$OUT"/pimoroni-*-tufty.uf2 <<'EOF'
import struct, sys
LIMIT, rc = 0x10200000, 0
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    lo, hi, fams = 2**32, 0, set()
    for i in range(0, len(d), 512):
        m0, m1, flags, addr, size, no, total, fam = struct.unpack_from('<8I', d, i)
        assert (m0, m1) == (0x0A324655, 0x9E5D5157), path + ": bad magic"
        fams.add(fam if flags & 0x2000 else None)
        lo, hi = min(lo, addr), max(hi, addr + size)
    ok = fams == {0xe48bff59} and 0x10000000 <= lo and hi <= LIMIT
    print(f"{path}: {len(d)//512} blocks, family {','.join(hex(f) for f in fams if f)}, "
          f"0x{lo:08x}..0x{hi:08x} -> {'OK' if ok else 'FAIL'}")
    rc |= not ok
sys.exit(rc)
EOF

for d in "${DEMOS[@]}"; do "$PICOTOOL" info -a "$OUT/pimoroni-$d-tufty.uf2"; done
echo "done: $OUT"
