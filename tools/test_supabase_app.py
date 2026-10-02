#!/usr/bin/env python3
"""Host test of the dual-boot launch path (docs/DUALBOOT.md).

    python3 tools/test_supabase_app.py zig-out/firmware/snouty-tufty-arcade-supabase.uf2
    (or: zig build supabase-test)

1. The launcher app's logic (supabase-app/snouty_arcade/snouty_dualboot.py)
   against the flash contents the UF2 writes, with a fake machine.mem32 that
   reads back signed values as MicroPython's does: header and stub checks,
   where the stub goes, its relocation, and the exact watchdog register
   sequence of the RAM_IMAGE reboot.
2. If the `unicorn` module is installed, the launch stub itself, emulated
   as a Cortex-M33 from the address the app put it at, with the bootrom
   functions it calls mocked: the call order and arguments, the flash read
   mode search, the chain_image() call, and every failure path down to the
   watchdog writes.
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "supabase-app", "snouty_arcade"))
import snouty_dualboot as db  # noqa: E402

failures = 0


def check(cond, what):
    global failures
    if not cond:
        failures += 1
        print("FAIL:", what)


def load_uf2(path):
    flash = {}
    data = open(path, "rb").read()
    for i in range(len(data) // 512):
        b = data[i * 512:(i + 1) * 512]
        addr, size = struct.unpack("<II", b[12:20])
        for j in range(size):
            flash[addr + j] = b[32 + j]
    return flash


class Mem32:
    """machine.mem32 over a byte dict: reads come back signed, as on
    MicroPython (extmod/machine_mem.c mp_obj_new_int of a uint32)."""

    def __init__(self, flash):
        self.b = dict(flash)
        self.writes = []
        self.ticks_on = True

    def __getitem__(self, a):
        if a == db.TICKS_WATCHDOG_CTRL:
            v = 1 if self.ticks_on else 0
        else:
            v = sum(self.b.get(a + i, 0xFF if 0x10000000 <= a < 0x11000000 else 0) << (8 * i) for i in range(4))
        return v - (1 << 32) if v & 0x80000000 else v

    def __setitem__(self, a, v):
        v &= 0xFFFFFFFF
        self.writes.append((a, v))
        for i in range(4):
            self.b[a + i] = (v >> (8 * i)) & 0xFF


def test_launcher(flash, stub_bin):
    check(db.crc32(b"123456789") == 0xCBF43926, "crc32 check value")
    check(db.crc32(stub_bin) == zlib.crc32(stub_bin), "crc32 == zlib.crc32")

    m = Mem32(flash)
    stub_len, stub_crc = db.read_header(m)
    check(stub_len == len(stub_bin) and stub_crc == zlib.crc32(stub_bin), "header describes the stub")
    words = db.read_stub(m, stub_len, stub_crc)
    check(bytes(b for w in words for b in struct.pack("<I", w)) == stub_bin, "stub read from flash == dualboot-stub.bin")

    # Erased flash: not installed.
    try:
        db.read_header(Mem32({}))
        check(False, "erased flash accepted")
    except db.LaunchError as e:
        check("not installed" in str(e), "erased flash message")
    # A damaged stub byte.
    bad = dict(flash)
    bad[db.LAUNCHER + db.STUB_OFFSET + 40] ^= 0x10
    try:
        db.read_stub(Mem32(bad), stub_len, stub_crc)
        check(False, "damaged stub accepted")
    except db.LaunchError:
        pass

    # Where the stub goes.
    check(db.stub_base(0x20010004, 307200, stub_len) == 0x20010100, "stub aligned up to 256")
    check(db.stub_base(0x20010000, 307200, stub_len) == 0x20010000, "aligned buffer used as is")
    for addr, n in ((0x11000000, 307200), (0x2007FF00, 307200), (0x20000004, 0x100)):
        try:
            db.stub_base(addr, n, stub_len)
            check(False, "bad buffer 0x%08x accepted" % addr)
        except db.LaunchError:
            pass

    fb = 0x2001A2C4  # some framebuffer address in main SRAM
    base, size = db.prepare(m, fb, 307200)
    check(base == 0x2001A300 and size == len(stub_bin), "prepare: base and size")
    placed = [db.u32(m[base + 4 * i]) for i in range(len(words))]
    check(placed[0] == 0x20082000, "SP word untouched")
    check(placed[1:4] == [w + base for w in words[1:4]] and all(p & 1 for p in placed[1:4]), "vector words relocated, Thumb bit kept")
    check(placed[4:] == words[4:], "rest of the stub verbatim")
    check(m.writes[0] == (db.WD_SCRATCH0, 0), "prepare clears the last failure code first")

    for ticks_on in (True, False):
        m.writes = []
        m.ticks_on = ticks_on
        db.run_reboot(m, base, size)
        expect = [
            (0x400D8000, 0),
            (0x40018008, 0x01FFFFFE),
            (0x400D8014, base),
            (0x400D8018, size),
            (0x400D801C, 0),
            (0x400D8024, 3),
            (0x400D8028, 0xB007C0D3),
            (0x400D801C, 0xB007C0D3),
            (0x400D8020, 0xFFFFFFFE),
            (0x400D8004, 10000),
        ]
        if not ticks_on:
            expect += [(0x40108034, 12), (0x40108030, 1)]
        expect += [(0x4000A014, 1), (0x400D8000, 0x40000000)]
        check(m.writes == expect, "reboot register sequence (ticks %s): %s" % (ticks_on, [(hex(a), hex(v)) for a, v in m.writes]))
    # The bootrom's validity rule (varm_boot_path.c): pc_mod ^ -magic == pc, and for the magic pc, pc_mod == -2.
    s4, s5, s7 = 0xB007C0D3, 0xFFFFFFFE, 0xB007C0D3
    check((s5 ^ ((-s4) & 0xFFFFFFFF)) == s7 and s5 == (-2) & 0xFFFFFFFF, "scratch vector parity")

    # Failure codes from the stub.
    for code, detail, want in ((3, (-17) & 0xFFFFFFFF, "NOT_FOUND"), (1, 0x4943, "(CI)"), (4, 0x2001A3F0, "0x2001a3f0"), (2, 0, "read mode")):
        f = Mem32({})
        f[db.WD_SCRATCH0] = db.RESULT_MAGIC | code
        f[db.WD_SCRATCH1] = detail
        msg = db.last_failure(f)
        check(msg is not None and want in msg, "failure %d decodes (%s)" % (code, msg))
        check(db.u32(f[db.WD_SCRATCH0]) == 0 and db.last_failure(f) is None, "failure %d cleared" % code)
    check(db.last_failure(Mem32({})) is None, "no failure recorded")
    return base


def test_stub_emulated(flash, stub_bin, base):
    try:
        import unicorn as uc
        from unicorn import arm_const as A
    except ImportError:
        print("skip: stub emulation (pip install unicorn to run it)")
        return

    ROM_LOOKUP = 0x200
    FN = {b"RA": 0x300, b"IF": 0x310, b"EX": 0x320, b"XM": 0x330, b"FC": 0x340, b"CI": 0x350}
    hdr_raw = bytes(flash[db.LAUNCHER + i] for i in range(0x1000) if db.LAUNCHER + i in flash)

    def run(working_mode, chain_rc, missing=None):
        mu = uc.Uc(uc.UC_ARCH_ARM, uc.UC_MODE_THUMB | uc.UC_MODE_MCLASS, cpu=uc.arm_const.UC_CPU_ARM_CORTEX_M33)
        mu.mem_map(0x0, 0x1000)  # bootrom
        mu.mem_write(0x16, struct.pack("<H", ROM_LOOKUP | 1))
        for a in [ROM_LOOKUP] + list(FN.values()):
            mu.mem_write(a, b"\x70\x47")  # bx lr (the hook does the work)
        mu.mem_map(0x20000000, 0x82000)  # SRAM incl. SCRATCH_X/Y
        placed = list(struct.unpack("<%dI" % (len(stub_bin) // 4), stub_bin))
        for i in (1, 2, 3):
            placed[i] += base
        mu.mem_write(base, struct.pack("<%dI" % len(placed), *placed))
        mu.mem_map(0x1C14F000, 0x1000)  # launcher sector, uncached untranslated alias
        for a, n in ((0x40008000, 0x3000), (0x40018000, 0x1000), (0x400D8000, 0x1000), (0x40108000, 0x1000)):
            mu.mem_map(a, n)
        calls, writes = [], []
        state = {"mode": None}

        def set_flash():
            ok = state["mode"] == working_mode
            mu.mem_write(0x1C14F000, hdr_raw.ljust(0x1000, b"\xff") if ok else b"\x00" * 0x1000)

        set_flash()

        def on_code(mu, addr, size, _):
            if addr == ROM_LOOKUP:
                code = mu.reg_read(A.UC_ARM_REG_R0)
                key = bytes((code & 0xFF, code >> 8))
                calls.append(("lookup", key, mu.reg_read(A.UC_ARM_REG_R1)))
                mu.reg_write(A.UC_ARM_REG_R0, 0 if key == missing else FN[key] | 1)
                return
            for key, a in FN.items():
                if addr == a:
                    r = [mu.reg_read(getattr(A, "UC_ARM_REG_R%d" % i)) for i in range(4)]
                    if key == b"XM":
                        state["mode"] = (r[0], r[1])
                        set_flash()
                        calls.append((key, r[0], r[1]))
                    elif key == b"CI":
                        calls.append((key, r[0], r[1], r[2], r[3]))
                        if chain_rc is None:
                            mu.emu_stop()  # launched
                        mu.reg_write(A.UC_ARM_REG_R0, chain_rc & 0xFFFFFFFF if chain_rc is not None else 0)
                    else:
                        calls.append((key,))
            if addr == state.get("last_pc"):
                mu.emu_stop()  # `b .`: the watchdog would reset here
            state["last_pc"] = addr

        def on_write(mu, access, addr, size, value, _):
            if addr >= 0x40000000:
                writes.append((addr, value & 0xFFFFFFFF))

        mu.hook_add(uc.UC_HOOK_CODE, on_code)
        mu.hook_add(uc.UC_HOOK_MEM_WRITE, on_write)
        mu.reg_write(A.UC_ARM_REG_SP, placed[0])
        mu.emu_start(placed[1], 0, count=20000)
        return calls, writes, mu

    lookups = [("lookup", k, 4) for k in (b"RA", b"IF", b"EX", b"XM", b"FC", b"CI")]
    order = [(m, d) for d in (3, 6, 12, 24) for m in (3, 2, 1, 0)]  # datasheet table 463
    chain = (b"CI", 0x20080000, 0x1000, 0x10150000, 0xB0000)

    # EBh quad at clkdiv 3 works: straight in.
    calls, writes, mu = run((3, 3), None)
    check(calls == lookups + [(b"RA",), (b"IF",), (b"EX",), (b"XM", 3, 3), (b"FC",), chain], "stub: happy path %s" % calls)
    check(writes == [], "stub: happy path writes no peripheral register")

    # Only 03h serial at clkdiv 12 works: the bootrom's search order up to it.
    calls, _, _ = run((0, 12), None)
    xm = [c[1:] for c in calls if c[0] == b"XM"]
    check(xm == order[:order.index((0, 12)) + 1], "stub: read mode search order %s" % xm)
    check(calls[-2:] == [(b"FC",), chain], "stub: flush then chain after the search")

    def fail_writes(code, detail):
        return [
            (0x400D8000, 0), (0x400D800C, 0x534E0000 | code), (0x400D8010, detail & 0xFFFFFFFF),
            (0x400D801C, 0), (0x40018008, 0x01FFFFFE), (0x40108034, 12), (0x40108030, 1),
            (0x400D8004, 1000), (0x4000A014, 1), (0x400D8000, 0x40000000),
        ]

    # chain_image() refuses: code 3 with its error, then the watchdog reboot.
    calls, writes, _ = run((3, 3), -17)
    check(writes == fail_writes(3, -17), "stub: chain_image failure path %s" % [(hex(a), hex(v)) for a, v in writes])

    # No mode works: all 16 tried, code 2.
    calls, writes, _ = run(None, None)
    check([c[1:] for c in calls if c[0] == b"XM"] == order, "stub: all 16 modes tried")
    check(not any(c[0] == b"CI" for c in calls), "stub: no chain_image without the header")
    check(writes == fail_writes(2, 0), "stub: no-mode failure path")

    # A bootrom function missing: code 1 with its 2-letter code.
    calls, writes, _ = run((3, 3), None, missing=b"CI")
    check(writes == fail_writes(1, 0x4943), "stub: missing function path")
    print("stub emulation: %d scenarios" % 5)


def main():
    uf2 = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "zig-out", "firmware", "snouty-tufty-arcade-supabase.uf2")
    stub_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(uf2), "..", "supabase-debug", "dualboot-stub.bin")
    flash = load_uf2(uf2)
    check(min(flash) >= db.LAUNCHER and max(flash) < db.GAP_END, "UF2 inside the gap")
    stub_bin = open(stub_path, "rb").read()
    base = test_launcher(flash, stub_bin)
    test_stub_emulated(flash, stub_bin, base)
    if failures:
        print("%d check(s) failed" % failures)
        sys.exit(1)
    print("supabase app + stub: all checks passed")


if __name__ == "__main__":
    main()
