# Snouty Arcade dual-boot launch (docs/DUALBOOT.md in snouty-tufty).
#
# Pure logic, no badge imports: __init__.py passes in machine.mem32, and the
# host test (tools/test_supabase_app.py) a fake memory. Works on MicroPython
# and CPython.
#
# How the arcade starts:
#   1. Check the launcher sector at 0x1014F000 that the dual-boot UF2 wrote
#      (magic, version, the launch stub's CRC-32).
#   2. Copy the stub into SRAM (the display framebuffer, which is in main
#      SRAM; the MicroPython heap is in PSRAM, which does not survive a
#      reset) at a 256-byte aligned address, and add that address to its
#      vector words 1..3.
#   3. Reboot through the watchdog with the bootrom's RAM_IMAGE boot type,
#      exactly as the bootrom's own reboot() does it (pico-bootrom-rp2350
#      varm_apis.c s_varm_hx_reboot; RP2350 datasheet 5.2.4, 5.2.4.1):
#        SCRATCH4 = 0xb007c0d3, SCRATCH5 = SCRATCH7 ^ -SCRATCH4 = 0xfffffffe,
#        SCRATCH6 = 3 (RAM_IMAGE), SCRATCH7 = 0xb007c0d3,
#        SCRATCH2 = stub address, SCRATCH3 = stub size.
#      The bootrom then runs the stub in a freshly reset chip, and the stub
#      chains into the arcade in flash (stub.S).
# Nothing here writes flash. If anything fails, the badge reboots into
# MicroPython (or, if the bootrom refuses the stub, into BOOTSEL: press
# RESET).

LAUNCHER = 0x1014F000
MAGIC = (0x554F4E53, 0x42445954, 0xAAB0B1AC, 0xBDBBA6AB)  # "SNOUTYDB", then ~
VERSION = 1
STUB_OFFSET = 0x40
STUB_MAX = 4096 - STUB_OFFSET
WINDOW_BASE = 0x10150000
WINDOW_SIZE = 0xB0000
GAP_END = 0x10200000

SRAM_BASE = 0x20000000
SRAM_MAIN_END = 0x20080000
STUB_ALIGN = 256
STUB_STACK_TOP = 0x20082000

RESULT_MAGIC = 0x534E0000

WATCHDOG = 0x400D8000
WD_CTRL = WATCHDOG + 0x00
WD_LOAD = WATCHDOG + 0x04
WD_SCRATCH0 = WATCHDOG + 0x0C
WD_SCRATCH1 = WATCHDOG + 0x10
WD_SCRATCH2 = WATCHDOG + 0x14
WD_SCRATCH3 = WATCHDOG + 0x18
WD_SCRATCH4 = WATCHDOG + 0x1C
WD_SCRATCH5 = WATCHDOG + 0x20
WD_SCRATCH6 = WATCHDOG + 0x24
WD_SCRATCH7 = WATCHDOG + 0x28
WD_CTRL_ENABLE = 0x40000000
PSM_WDSEL = 0x40018000 + 0x08
PSM_WDSEL_ALL_BUT_PROC_COLD = 0x01FFFFFE  # PSM_WDSEL_BITS & ~PSM_WDSEL_PROC_COLD_BITS
TICKS_WATCHDOG_CTRL = 0x40108000 + 0x30
TICKS_WATCHDOG_CYCLES = 0x40108000 + 0x34
SYSCFG_AUXCTRL_SET = 0x40008000 + 0x2000 + 0x14  # atomic set alias

BOOT_MAGIC = 0xB007C0D3
BOOT_TYPE_RAM_IMAGE = 3
REBOOT_DELAY_MS = 10

FAILURES = {
    1: "a bootrom function is missing",
    2: "no flash read mode reads the launcher sector",
    3: "the bootrom refused the arcade image (chain_image)",
    4: "the launch stub crashed",
}
BOOTROM_ERRORS = {
    -4: "NOT_PERMITTED", -5: "INVALID_ARG", -10: "INVALID_ADDRESS", -11: "BAD_ALIGNMENT",
    -12: "INVALID_STATE", -13: "BUFFER_TOO_SMALL", -14: "PRECONDITION_NOT_MET",
    -15: "MODIFIED_DATA", -16: "INVALID_DATA", -17: "NOT_FOUND", -18: "UNSUPPORTED_MODIFICATION",
    -19: "LOCK_REQUIRED",
}


class LaunchError(Exception):
    pass


def u32(v):
    # machine.mem32 reads come back signed on MicroPython.
    return v & 0xFFFFFFFF


def crc32(data):
    """CRC-32 (zlib), bitwise: small, and the same on every MicroPython build."""
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return crc ^ 0xFFFFFFFF


def read_words(mem32, addr, n):
    return [u32(mem32[addr + 4 * i]) for i in range(n)]


def read_header(mem32):
    """The stub length and CRC from the launcher sector, or LaunchError."""
    w = read_words(mem32, LAUNCHER, 13)
    if tuple(w[0:4]) != MAGIC:
        raise LaunchError("Snouty Arcade is not installed: flash snouty-tufty-arcade-supabase.uf2 first.")
    if w[4] != VERSION or w[5] != STUB_OFFSET:
        raise LaunchError("This launcher does not match the installed Snouty Arcade (header v%d)." % w[4])
    if (w[8], w[9], w[12]) != (WINDOW_BASE, WINDOW_SIZE, GAP_END):
        raise LaunchError("The installed Snouty Arcade has an unexpected flash layout.")
    stub_len, stub_crc = w[6], w[7]
    if stub_len == 0 or stub_len > STUB_MAX or stub_len % 4:
        raise LaunchError("The launch stub size is wrong (%d bytes)." % stub_len)
    return stub_len, stub_crc


def read_stub(mem32, stub_len, stub_crc):
    words = read_words(mem32, LAUNCHER + STUB_OFFSET, stub_len // 4)
    data = bytearray()
    for v in words:
        data.extend(bytes((v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24)))
    if crc32(data) != stub_crc:
        raise LaunchError("The launch stub in flash is damaged (CRC mismatch).")
    if words[0] != STUB_STACK_TOP or words[4] != 0xFFFFDED3:
        raise LaunchError("The launch stub in flash is not one this launcher knows.")
    for i in (1, 2, 3):
        if words[i] & 1 == 0 or words[i] >= stub_len:
            raise LaunchError("The launch stub's vector table is wrong.")
    return words


def stub_base(buffer_addr, buffer_len, stub_len):
    """Where to put the stub inside the buffer: 256-byte aligned, and all of
    it inside main SRAM (not SCRATCH_X/Y: the stub uses those after the
    reboot for its stack and the chain_image work area)."""
    base = (buffer_addr + STUB_ALIGN - 1) & ~(STUB_ALIGN - 1)
    end = base + stub_len
    if buffer_addr < SRAM_BASE or end > buffer_addr + buffer_len or end > SRAM_MAIN_END:
        raise LaunchError("No SRAM buffer for the launch stub (display buffer at 0x%08x)." % buffer_addr)
    return base


def place_stub(mem32, base, words):
    """Copy the stub to `base`, relocate vector words 1..3, verify."""
    placed = list(words)
    for i in (1, 2, 3):
        placed[i] = words[i] + base
    for i, v in enumerate(placed):
        mem32[base + 4 * i] = v
    if read_words(mem32, base, len(placed)) != placed:
        raise LaunchError("The launch stub did not read back from SRAM.")
    return placed


def reboot_sequence(base, size):
    """The register writes of the bootrom's reboot(REBOOT_TYPE_RAM_IMAGE,
    REBOOT_DELAY_MS, base, size), in its order. A read-modify step is a
    tuple ("tick",) handled by run_reboot."""
    return [
        (WD_CTRL, 0),                                  # watchdog off, PAUSE bits clear
        (PSM_WDSEL, PSM_WDSEL_ALL_BUT_PROC_COLD),      # full reset on trigger
        (WD_SCRATCH2, base),                           # p0: RAM window base
        (WD_SCRATCH3, size),                           # p1: RAM window size
        (WD_SCRATCH4, 0),
        (WD_SCRATCH6, BOOT_TYPE_RAM_IMAGE),            # "sp" = boot type
        (WD_SCRATCH7, BOOT_MAGIC),                     # "pc" = magic: a special boot type
        (WD_SCRATCH4, BOOT_MAGIC),
        (WD_SCRATCH5, BOOT_MAGIC ^ ((-BOOT_MAGIC) & 0xFFFFFFFF)),  # = 0xfffffffe
        (WD_LOAD, REBOOT_DELAY_MS * 1000),
        ("tick",),                                     # watchdog tick running (1 us)
        (SYSCFG_AUXCTRL_SET, 1),                       # POWMAN clock off clk_ref first
        (WD_CTRL, WD_CTRL_ENABLE),                     # count down, then reset
    ]


def run_reboot(mem32, base, size):
    for step in reboot_sequence(base, size):
        if step[0] == "tick":
            if u32(mem32[TICKS_WATCHDOG_CTRL]) & 1 == 0:
                mem32[TICKS_WATCHDOG_CYCLES] = 12
                mem32[TICKS_WATCHDOG_CTRL] = 1
        else:
            mem32[step[0]] = step[1]


def last_failure(mem32):
    """What the stub left in SCRATCH0/1 if the last launch failed (a
    message), else None. Clears it."""
    code = u32(mem32[WD_SCRATCH0])
    if code & 0xFFFF0000 != RESULT_MAGIC:
        return None
    detail = u32(mem32[WD_SCRATCH1])
    mem32[WD_SCRATCH0] = 0
    mem32[WD_SCRATCH1] = 0
    what = FAILURES.get(code & 0xFFFF, "unknown failure %d" % (code & 0xFFFF))
    if code & 0xFFFF == 1:
        what += " (%s%s)" % (chr(detail & 0xFF), chr((detail >> 8) & 0xFF))
    elif code & 0xFFFF == 3:
        rc = detail - (1 << 32) if detail & 0x80000000 else detail
        what += " (%s)" % BOOTROM_ERRORS.get(rc, str(rc))
    elif code & 0xFFFF == 4:
        what += " (pc 0x%08x)" % detail
    return what


def prepare(mem32, buffer_addr, buffer_len):
    """Everything up to the reboot: returns (base, size) for run_reboot."""
    stub_len, stub_crc = read_header(mem32)
    words = read_stub(mem32, stub_len, stub_crc)
    base = stub_base(buffer_addr, buffer_len, stub_len)
    mem32[WD_SCRATCH0] = 0
    place_stub(mem32, base, words)
    return base, stub_len
