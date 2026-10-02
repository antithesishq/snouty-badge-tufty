//! The FAT12 "drive" image an XIP cart's UF2 carries (pure, host-tested).
//!
//! The SYCL badge OS keeps a FAT12 super-floppy in its `romfs` flash region
//! (0x10080000, 1280 KB; sycl-badge src/os/linker.ld, storage.zig
//! formatVolume) and shows it as a USB drive. The genesis cart reads its ROM
//! from that volume in place (snouty-badge lib/romfs.zig). The Tufty has no
//! such drive, so the UF2 writes one: this is the volume the SYCL OS would
//! format (same geometry, field for field as snouty-badge
//! tools/make_romfs.py, label SYCLBADGE) with one file, the ROM, in
//! clusters 2.. (contiguous, so the cart takes its fast path). The image is
//! cut after the ROM's last sector, like `make_romfs.py --truncate`: the
//! volume still claims the whole 1280 KB, and the reader never touches a
//! free cluster, so the flash past the image may hold anything.
//!
//! No allocator in the writer, no floats, nothing heavy at comptime.
const std = @import("std");

pub const sector = 512;
/// The SYCL romfs region: the volume size the OS formats.
pub const volume_bytes: u32 = 1280 * 1024;
pub const total_sectors: u32 = volume_bytes / sector;

const reserved: u32 = 1;
const num_fats: u32 = 2;
const root_entries: u32 = 32;
const root_sectors: u32 = (root_entries * 32 + sector - 1) / sector;
const media: u8 = 0xF8;
const eoc: u16 = 0xFFF;
/// 2026-09-29 12:00:00, FAT packed (make_romfs.py's fixed timestamp).
const fat_date: u16 = ((2026 - 1980) << 9) | (9 << 5) | 29;
const fat_time: u16 = 12 << 11;

/// storage.zig fatSectors() / make_romfs.py fat_sectors(): iterate until
/// the FAT covers the data clusters.
pub fn fat_sectors(total: u32) u32 {
    var fs: u32 = 1;
    while (true) {
        const data = total - reserved - root_sectors - num_fats * fs;
        const need = ((data * 3 + 1) / 2 + sector - 1) / sector;
        if (need == fs) return fs;
        fs = need;
    }
}

pub const Layout = struct {
    fat_sectors: u32,
    root_start: u32,
    /// First data sector (cluster 2).
    data_start: u32,
    /// Data clusters on the volume (valid cluster numbers 2..clusters+1).
    clusters: u32,
};

pub fn layout() Layout {
    const fs = fat_sectors(total_sectors);
    const root_start = reserved + num_fats * fs;
    const data_start = root_start + root_sectors;
    return .{ .fat_sectors = fs, .root_start = root_start, .data_start = data_start, .clusters = total_sectors - data_start };
}

/// Clusters (= sectors) a file of `len` bytes takes.
pub fn clusters_for(len: usize) u32 {
    return @intCast((len + sector - 1) / sector);
}

/// Largest ROM the volume holds.
pub fn max_rom_bytes() u32 {
    return layout().clusters * sector;
}

/// Bytes of the truncated image for a ROM of `rom_len` bytes: the boot
/// sector, both FATs, the root directory and the ROM's clusters.
pub fn image_len(rom_len: usize) usize {
    return (@as(usize, layout().data_start) + clusters_for(rom_len)) * sector;
}

/// Byte offset of the ROM's first byte in the image (cluster 2).
pub fn rom_offset() u32 {
    return layout().data_start * sector;
}

/// The extensions the genesis cart scans (cart/src/frontend/drive.zig).
const rom_exts = [_][]const u8{ "GEN", "MD", "BIN" };

/// The 8.3 directory name for a ROM file called `basename`: upper case,
/// the base cut to 8 characters, characters FAT does not allow in a short
/// name as '_'. The extension is kept if the cart scans it (gen, md, bin),
/// otherwise it becomes BIN, so the cart always finds the file.
/// "sonic1.bin" -> "SONIC1  BIN", "miniplanets.bin" -> "MINIPLANBIN".
pub fn short_name(basename: []const u8) [11]u8 {
    var out: [11]u8 = @splat(' ');
    const dot = std.mem.lastIndexOfScalar(u8, basename, '.');
    const base = if (dot) |d| basename[0..d] else basename;
    const ext = if (dot) |d| basename[d + 1 ..] else "";

    var n: usize = 0;
    for (base) |ch| {
        if (n == 8) break;
        if (ch == ' ' or ch == '.') continue;
        out[n] = sfn_char(ch);
        n += 1;
    }
    if (n == 0) out[0] = '_';

    var ext_up: [3]u8 = @splat(' ');
    var e: usize = 0;
    for (ext) |ch| {
        if (e == 3) break;
        ext_up[e] = std.ascii.toUpper(ch);
        e += 1;
    }
    const scanned = for (rom_exts) |want| {
        if (want.len == ext.len and std.mem.eql(u8, want, ext_up[0..want.len])) break true;
    } else false;
    @memcpy(out[8..11], if (scanned) &ext_up else "BIN");
    return out;
}

fn sfn_char(ch: u8) u8 {
    const up = std.ascii.toUpper(ch);
    if (std.ascii.isAlphanumeric(up)) return up;
    return if (std.mem.indexOfScalar(u8, "!#$%&'()-@^_`{}~", up) != null) up else '_';
}

/// "SONIC1  BIN" -> "SONIC1.BIN" (into `buf`).
pub fn display_name(n11: *const [11]u8, buf: *[12]u8) []const u8 {
    var n: usize = 0;
    for (n11[0..8]) |ch| {
        if (ch == ' ') break;
        buf[n] = ch;
        n += 1;
    }
    if (n11[8] != ' ') {
        buf[n] = '.';
        n += 1;
        for (n11[8..11]) |ch| {
            if (ch == ' ') break;
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

pub const Error = error{ RomEmpty, RomTooLarge, BadOutputSize };

fn put16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}

fn put32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

/// formatVolume()'s boot sector (make_romfs.py boot_sector()).
fn boot_sector(b: []u8, fs: u32) void {
    @memcpy(b[0..3], "\xEB\x3C\x90");
    @memcpy(b[3..11], "SYCLBADG");
    put16(b, 11, sector);
    b[13] = 1; // sectors per cluster
    put16(b, 14, reserved);
    b[16] = num_fats;
    put16(b, 17, root_entries);
    put16(b, 19, total_sectors);
    b[21] = media;
    put16(b, 22, @intCast(fs));
    put16(b, 24, 32); // sectors per track
    put16(b, 26, 64); // heads
    put32(b, 28, 0); // hidden sectors
    put32(b, 32, 0); // large total
    b[36] = 0x80;
    b[38] = 0x29;
    put32(b, 39, 0x20260120);
    @memcpy(b[43..54], "SYCLBADGE  ");
    @memcpy(b[54..62], "FAT12   ");
    put16(b, 510, 0xAA55);
}

fn fat_set(fat: []u8, cluster: u32, value: u16) void {
    const off = cluster + cluster / 2;
    const v = value & 0xFFF;
    if (cluster & 1 != 0) {
        fat[off] = (fat[off] & 0x0F) | @as(u8, @truncate(v << 4));
        fat[off + 1] = @truncate(v >> 4);
    } else {
        fat[off] = @truncate(v);
        fat[off + 1] = (fat[off + 1] & 0xF0) | @as(u8, @truncate(v >> 8));
    }
}

fn dir_entry(e: []u8, n11: *const [11]u8, attr: u8, cluster: u16, size: u32) void {
    @memset(e[0..32], 0);
    @memcpy(e[0..11], n11);
    e[11] = attr;
    put16(e, 14, fat_time);
    put16(e, 16, fat_date);
    put16(e, 18, fat_date);
    put16(e, 22, fat_time);
    put16(e, 24, fat_date);
    put16(e, 26, cluster);
    put32(e, 28, size);
}

/// Writes the drive image for `rom`, stored as `name` (an 8.3 name from
/// `short_name`), into `out`, which must be exactly `image_len(rom.len)`
/// bytes.
pub fn write(out: []u8, rom: []const u8, name: [11]u8) Error!void {
    if (rom.len == 0) return error.RomEmpty;
    if (rom.len > max_rom_bytes()) return error.RomTooLarge;
    if (out.len != image_len(rom.len)) return error.BadOutputSize;
    const l = layout();
    @memset(out, 0);

    boot_sector(out[0..sector], l.fat_sectors);

    // FAT: media descriptor, then the ROM's chain 2 -> 3 -> ... -> EOC.
    const fat_bytes = l.fat_sectors * sector;
    const fat = out[reserved * sector ..][0..fat_bytes];
    fat[0] = media;
    fat[1] = 0xFF;
    fat[2] = 0xFF;
    const n = clusters_for(rom.len);
    var c: u32 = 2;
    while (c < 2 + n) : (c += 1) fat_set(fat, c, if (c + 1 < 2 + n) @intCast(c + 1) else eoc);
    // The second FAT is a copy of the first.
    @memcpy(out[(reserved + l.fat_sectors) * sector ..][0..fat_bytes], fat);

    // Root directory: the volume label, then the ROM.
    const root = out[l.root_start * sector ..][0 .. root_sectors * sector];
    dir_entry(root[0..32], "SYCLBADGE  ", 0x08, 0, 0);
    dir_entry(root[32..64], &name, 0x20, 2, @intCast(rom.len));

    @memcpy(out[l.data_start * sector ..][0..rom.len], rom);
}

// ========================================
// Tests
// ========================================

const testing = std.testing;
const romfs = @import("romfs");

test "geometry is the SYCL OS's 1280 KB volume" {
    const l = layout();
    // make_romfs.py on a 1280K volume: FAT 8 sectors x2, data from sector 19.
    try testing.expectEqual(@as(u32, 8), l.fat_sectors);
    try testing.expectEqual(@as(u32, 17), l.root_start);
    try testing.expectEqual(@as(u32, 19), l.data_start);
    try testing.expectEqual(@as(u32, 2541), l.clusters);
    // A 512 KB ROM: 19 + 1024 sectors.
    try testing.expectEqual(@as(usize, (19 + 1024) * 512), image_len(512 * 1024));
    try testing.expect(max_rom_bytes() >= 1024 * 1024);
}

test "8.3 names" {
    try testing.expectEqualStrings("SONIC1  BIN", &short_name("sonic1.bin"));
    try testing.expectEqualStrings("MINIPLANBIN", &short_name("miniplanets.bin"));
    try testing.expectEqualStrings("GAME    GEN", &short_name("Game.gen"));
    try testing.expectEqualStrings("A_B     MD ", &short_name("a+b.md"));
    try testing.expectEqualStrings("ROM     BIN", &short_name("rom.smd"));
    try testing.expectEqualStrings("SONICTHEBIN", &short_name("Sonic The Hedgehog (W).bin"));
    try testing.expectEqualStrings("NOEXT   BIN", &short_name("noext"));
    var buf: [12]u8 = undefined;
    try testing.expectEqualStrings("SONIC1.BIN", display_name(&short_name("sonic1.bin"), &buf));
}

/// A fake ROM: `len` bytes of a pattern, with a "SEGA" header at 0x100.
fn fake_rom(buf: []u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i *% 7 +% (i >> 9));
    @memcpy(buf[0x100..0x110], "SEGA MEGA DRIVE ");
    return buf;
}

fn round_trip(rom_len: usize, name: []const u8) !void {
    const rom = fake_rom(try testing.allocator.alloc(u8, rom_len));
    defer testing.allocator.free(rom);
    const img = try testing.allocator.alloc(u8, image_len(rom.len));
    defer testing.allocator.free(img);
    try write(img, rom, short_name(name));

    // Read it back with the cart's own reader, as the badge does (the
    // image stands in for the 1280 KB region, cut after its last sector).
    const vol = try romfs.Volume.open(romfs.Image.truncated_test(img));
    var entries: [4]romfs.Entry = undefined;
    const exts = [_][]const u8{ "gen", "md", "bin" };
    const n = vol.find(&exts, &entries);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, @intCast(rom.len)), entries[0].size);
    try testing.expectEqual(@as(u16, 2), entries[0].first_cluster);
    var clusters: [romfs.max_clusters]u16 = undefined;
    const m = try vol.map(entries[0], &clusters);
    // Contiguous: the cart reads it through one base pointer.
    const p = m.contiguous() orelse return error.NotContiguous;
    try testing.expectEqualSlices(u8, rom, p[0..rom.len]);
    try testing.expectEqual(@as(usize, rom_offset()), @intFromPtr(p) - @intFromPtr(img.ptr));
}

test "the cart's romfs reader finds the ROM, contiguous and byte-identical" {
    try round_trip(512 * 1024, "sonic1.bin");
    try round_trip(512 * 1024 + 3, "odd.gen");
    try round_trip(16 * 1024, "snouty-test.bin");
    try round_trip(max_rom_bytes(), "big.md");
}

test "refusals" {
    var img: [4096]u8 = undefined;
    try testing.expectError(error.RomEmpty, write(&img, &.{}, short_name("x.bin")));
    try testing.expectError(error.BadOutputSize, write(&img, "abc", short_name("x.bin")));
    const big = try testing.allocator.alloc(u8, max_rom_bytes() + 1);
    defer testing.allocator.free(big);
    try testing.expectError(error.RomTooLarge, write(&img, big, short_name("x.bin")));
}
