//! Dual-boot flash layout (docs/DUALBOOT.md). Pure, host-tested.
//!
//! The badge keeps its own firmware: MicroPython bw-1.29.0 (Supabase build,
//! `picotool info -a` on the owner's badge) occupies 0x10000000..0x1014E220,
//! its ROMFS 0x10200000..0x10300000 and its FAT drive 0x10300000..0x11000000.
//! There is no partition table. The dual-boot arcade lives in the free gap
//! between the end of the MicroPython binary and the ROMFS:
//!
//!   0x1014F000  launcher sector (4 KB): header + the RAM launch stub
//!               (stub.S) that the launcher app copies to SRAM
//!   0x10150000  arcade window (704 KB) up to 0x10200000: the Tufty OS with
//!               the carts. The bootrom maps it to 0x10000000 (QMI ATRANS)
//!               when stub.S chains into it, so it is linked at 0x10000000.
//!
//! Every UF2 block of the dual-boot build lands in 0x1014F000..0x10200000.
//! The bootrom's normal flash boot only searches the first 4 KB of flash
//! (and the second 4 KB as slot 1), so nothing in the gap is ever booted on
//! a normal reset: MicroPython stays the default.
const std = @import("std");

/// End of the MicroPython binary on the owner's badge (bw-1.29.0).
pub const micropython_end: u32 = 0x1014E220;
/// First flash sector (4 KB) after MicroPython. Nothing below is written.
pub const gap_start: u32 = 0x1014F000;
/// The badge's ROMFS starts here. Nothing at or above is written.
pub const gap_end: u32 = 0x1020_0000;

pub const sector: u32 = 4096;

/// The launcher sector: header, then the stub.
pub const launcher_sector: u32 = gap_start;
/// The arcade image window, searched by chain_image() (stub.S).
pub const window_base: u32 = gap_start + sector;
pub const window_size: u32 = gap_end - window_base;
/// Where the bootrom maps the window at run time (ATRANS0), and so the
/// arcade's link address.
pub const runtime_base: u32 = 0x1000_0000;

/// SRAM the launch stub uses after the reboot (stub.S): stack top
/// (SCRATCH_Y) and the chain_image work area (SCRATCH_X).
pub const stub_stack_top: u32 = 0x2008_2000;
pub const stub_workarea: u32 = 0x2008_0000;
/// Main SRAM: where the launcher app may place the stub.
pub const sram_base: u32 = 0x2000_0000;
pub const sram_main_end: u32 = 0x2008_0000;
/// The stub's load address alignment (VTOR needs 128; the app uses 256).
pub const stub_align: u32 = 256;

/// Launcher sector magic: "SNOUTYDB" and its bitwise complement. stub.S
/// probes for these 16 bytes to find a working flash read mode.
pub const magic = [4]u32{ 0x554F4E53, 0x42445954, ~@as(u32, 0x554F4E53), ~@as(u32, 0x42445954) };
pub const header_version: u32 = 1;
/// Header size; the stub follows it.
pub const stub_offset: u32 = 0x40;
pub const stub_max: u32 = sector - stub_offset;

/// Watchdog SCRATCH0 value the stub leaves when a launch fails (stub.S).
pub const result_magic: u32 = 0x534E_0000;

/// The launcher sector header, little-endian words:
///   0x00  magic[0..4]
///   0x10  header_version
///   0x14  stub_offset
///   0x18  stub length (bytes, a multiple of 4)
///   0x1C  stub CRC-32 (zlib)
///   0x20  window base, 0x24 window size
///   0x28  arcade image length, 0x2C its CRC-32
///   0x30  gap end, then zero
pub const Header = struct {
    stub_len: u32,
    stub_crc: u32,
    image_len: u32,
    image_crc: u32,

    pub fn encode(h: Header) [stub_offset]u8 {
        var out: [stub_offset]u8 = @splat(0);
        const words = [_]u32{
            magic[0],       magic[1],    magic[2],    magic[3],
            header_version, stub_offset, h.stub_len,  h.stub_crc,
            window_base,    window_size, h.image_len, h.image_crc,
            gap_end,
        };
        for (words, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
        return out;
    }

    pub fn decode(bytes: *const [stub_offset]u8) ?Header {
        const w = struct {
            fn at(b: *const [stub_offset]u8, i: usize) u32 {
                return std.mem.readInt(u32, b[i * 4 ..][0..4], .little);
            }
        }.at;
        for (magic, 0..) |m, i| if (w(bytes, i) != m) return null;
        if (w(bytes, 4) != header_version or w(bytes, 5) != stub_offset) return null;
        if (w(bytes, 8) != window_base or w(bytes, 9) != window_size or w(bytes, 12) != gap_end) return null;
        return .{ .stub_len = w(bytes, 6), .stub_crc = w(bytes, 7), .image_len = w(bytes, 10), .image_crc = w(bytes, 11) };
    }
};

pub fn crc32(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

comptime {
    // The gap starts on the first sector boundary after MicroPython, so the
    // sector erases the UF2 load does (one 4 KB sector per block written,
    // bootrom nsboot usb_virtual_disk.c) never touch MicroPython's last
    // sector, and ends on the ROMFS's first sector.
    std.debug.assert(gap_start % sector == 0 and gap_end % sector == 0);
    std.debug.assert(gap_start >= micropython_end and gap_start - micropython_end < sector);
    // The bootrom rolls ATRANS in whole sectors (varm_launch_image.c).
    std.debug.assert(window_base % sector == 0 and window_size % sector == 0);
    // Outside the bootrom's flash boot search: slot 0 and slot 1 (first 8 KB).
    std.debug.assert(launcher_sector >= 0x1000_2000);
}

// ========================================
// Tests
// ========================================

const testing = std.testing;

test "the gap and the window" {
    try testing.expectEqual(@as(u32, 0x1015_0000), window_base);
    try testing.expectEqual(@as(u32, 0xB_0000), window_size);
    try testing.expectEqual(@as(u32, 704 * 1024), window_size);
    try testing.expectEqual(@as(u32, 0xB1_000), gap_end - gap_start);
}

test "the header round-trips and rejects garbage" {
    const h: Header = .{ .stub_len = 384, .stub_crc = 0x1234_5678, .image_len = 600_000, .image_crc = 0xCAFE_F00D };
    var bytes = h.encode();
    try testing.expectEqual(h, Header.decode(&bytes).?);
    try testing.expectEqualSlices(u8, "SNOUTYDB", bytes[0..8]);
    bytes[3] ^= 1;
    try testing.expect(Header.decode(&bytes) == null);
    const erased: [stub_offset]u8 = @splat(0xFF);
    try testing.expect(Header.decode(&erased) == null);
}

/// The value of `.equ <name>, <hex>` in stub.S.
fn stub_equ(src: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t,");
        if (!std.mem.eql(u8, it.next() orelse continue, ".equ")) continue;
        if (!std.mem.eql(u8, it.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u32, it.next() orelse return null, 0) catch null;
    }
    return null;
}

test "stub.S agrees with this layout" {
    const src = @embedFile("stub.S");
    try testing.expectEqual(@as(?u32, stub_stack_top), stub_equ(src, "SRAM_END"));
    try testing.expectEqual(@as(?u32, stub_workarea), stub_equ(src, "WORKAREA"));
    try testing.expectEqual(@as(?u32, launcher_sector - 0x1000_0000 + 0x1C00_0000), stub_equ(src, "HDR_RAW"));
    try testing.expectEqual(@as(?u32, window_base), stub_equ(src, "WINDOW_BASE"));
    try testing.expectEqual(@as(?u32, window_size), stub_equ(src, "WINDOW_SIZE"));
    try testing.expectEqual(@as(?u32, magic[0]), stub_equ(src, "HDR_W0"));
    try testing.expectEqual(@as(?u32, magic[1]), stub_equ(src, "HDR_W1"));
    try testing.expectEqual(@as(?u32, magic[2]), stub_equ(src, "HDR_W2"));
    try testing.expectEqual(@as(?u32, magic[3]), stub_equ(src, "HDR_W3"));
    try testing.expectEqual(@as(?u32, result_magic), stub_equ(src, "RESULT_MAGIC"));
    // The work area (4 KB of SCRATCH_X) is at least what the SDK asks for
    // (pico/bootrom.h rom_chain_image: 3264 bytes).
    try testing.expect(stub_equ(src, "WORKAREA_SIZE").? >= 3264);
}
