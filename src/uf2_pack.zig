/// Merges extra flash regions into a firmware UF2 (pure, host-tested), used
/// by tools/uf2_pack.zig for XIP cart builds.
///
/// The output is one UF2 block sequence: the base firmware's blocks first
/// (payloads, addresses and flags unchanged), then each region cut into
/// 256-byte pages, every block family RP2350_ARM_S, `blockNo` / `numBlocks`
/// renumbered over the whole file. The bootrom writes each page where its
/// block says, so the regions land at their link addresses with no runtime
/// flash write. Regions must be 256-byte aligned and may not overlap each
/// other or the base; a region's last page is padded with zeros.
const std = @import("std");
const uf2_check = @import("uf2_check.zig");

pub const page = 256;
const block_size = uf2_check.block_size;
const magic_start0: u32 = 0x0A32_4655;
const magic_start1: u32 = 0x9E5D_5157;
const magic_end: u32 = 0x0AB1_6F30;
const flag_family_present: u32 = 0x0000_2000;

pub const Region = struct {
    addr: u32,
    bytes: []const u8,

    fn end(r: Region) u32 {
        return r.addr + pages(r.bytes.len) * page;
    }
};

pub const Error = error{ BadBase, Unaligned, EmptyRegion, Overlap, OutOfMemory };

fn pages(len: usize) u32 {
    return @intCast((len + page - 1) / page);
}

fn word(blk: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, blk[off..][0..4], .little);
}

fn put(blk: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, blk[off..][0..4], v, .little);
}

/// Address ranges [lo, hi) the base UF2 writes, one per block.
fn overlaps(base: []const u8, regions: []const Region) bool {
    for (regions, 0..) |r, i| {
        for (regions[i + 1 ..]) |q| {
            if (r.addr < q.end() and q.addr < r.end()) return true;
        }
        var off: usize = 0;
        while (off + block_size <= base.len) : (off += block_size) {
            const lo = word(base[off..], 12);
            const hi = lo + word(base[off..], 16);
            if (r.addr < hi and lo < r.end()) return true;
        }
    }
    return false;
}

/// Number of blocks `pack` writes.
pub fn block_count(base: []const u8, regions: []const Region) u32 {
    var n: u32 = @intCast(base.len / block_size);
    for (regions) |r| n += pages(r.bytes.len);
    return n;
}

/// The merged UF2 (caller frees).
pub fn pack(gpa: std.mem.Allocator, base: []const u8, regions: []const Region) Error![]u8 {
    switch (uf2_check.check(base, 0xFFFF_FFFF)) {
        .ok => {},
        .bad => return error.BadBase,
    }
    for (regions) |r| {
        if (r.addr % page != 0) return error.Unaligned;
        if (r.bytes.len == 0) return error.EmptyRegion;
    }
    if (overlaps(base, regions)) return error.Overlap;

    const total = block_count(base, regions);
    const out = try gpa.alloc(u8, @as(usize, total) * block_size);
    @memcpy(out[0..base.len], base);

    var n: u32 = @intCast(base.len / block_size);
    for (regions) |r| {
        var p: u32 = 0;
        while (p < pages(r.bytes.len)) : (p += 1) {
            const blk = out[@as(usize, n) * block_size ..][0..block_size];
            @memset(blk, 0);
            put(blk, 0, magic_start0);
            put(blk, 4, magic_start1);
            put(blk, 8, flag_family_present);
            put(blk, 12, r.addr + p * page);
            put(blk, 16, page);
            put(blk, 28, uf2_check.family_rp2350_arm_s);
            const src = r.bytes[p * page .. @min(r.bytes.len, (p + 1) * page)];
            @memcpy(blk[32..][0..src.len], src);
            put(blk, 508, magic_end);
            n += 1;
        }
    }
    // One sequence over the whole file.
    var i: u32 = 0;
    while (i < total) : (i += 1) {
        const blk = out[@as(usize, i) * block_size ..][0..block_size];
        put(blk, 20, i);
        put(blk, 24, total);
    }
    return out;
}

// ========================================
// Tests
// ========================================

const testing = std.testing;

fn base_uf2(buf: *[2 * block_size]u8) []u8 {
    for (0..2) |i| {
        const blk = buf[i * block_size ..][0..block_size];
        @memset(blk, 0);
        put(blk, 0, magic_start0);
        put(blk, 4, magic_start1);
        put(blk, 8, flag_family_present);
        put(blk, 12, 0x1000_0000 + @as(u32, @intCast(i)) * page);
        put(blk, 16, page);
        put(blk, 20, @intCast(i));
        put(blk, 24, 2);
        put(blk, 28, uf2_check.family_rp2350_arm_s);
        @memset(blk[32..][0..page], 0x11);
        put(blk, 508, magic_end);
    }
    return buf;
}

test "regions land at their addresses, numbered as one sequence" {
    var b: [2 * block_size]u8 = undefined;
    const base = base_uf2(&b);
    var drive: [600]u8 = undefined;
    for (&drive, 0..) |*x, i| x.* = @truncate(i);
    const xip = [_]u8{ 0xAB, 0xCD, 0xEF, 0x01 };
    const out = try pack(testing.allocator, base, &.{
        .{ .addr = 0x1008_0000, .bytes = &drive },
        .{ .addr = 0x101C_0000, .bytes = &xip },
    });
    defer testing.allocator.free(out);

    // 2 base + 3 drive pages + 1 xip page.
    try testing.expectEqual(@as(usize, 6 * block_size), out.len);
    const s = uf2_check.check(out, 0x1020_0000).ok;
    try testing.expectEqual(@as(u32, 6), s.blocks);
    try testing.expectEqual(@as(u32, 0x101C_0100), s.hi);
    for (0..6) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), word(out[i * block_size ..], 20));
        try testing.expectEqual(@as(u32, 6), word(out[i * block_size ..], 24));
    }

    const image = try testing.allocator.alloc(u8, s.hi - uf2_check.flash_base);
    defer testing.allocator.free(image);
    @memset(image, 0xFF);
    uf2_check.flatten(out, uf2_check.flash_base, image);
    try testing.expectEqualSlices(u8, &drive, image[0x8_0000..][0..drive.len]);
    // The drive's last page is padded with zeros.
    try testing.expectEqual(@as(u8, 0), image[0x8_0000 + drive.len]);
    try testing.expectEqualSlices(u8, &xip, image[0x1C_0000..][0..4]);
    try testing.expectEqual(@as(u8, 0x11), image[0]);
}

test "overlaps, misalignment and a bad base are refused" {
    var b: [2 * block_size]u8 = undefined;
    const base = base_uf2(&b);
    const data: [300]u8 = @splat(1);
    try testing.expectError(error.Overlap, pack(testing.allocator, base, &.{.{ .addr = 0x1000_0100, .bytes = &data }}));
    try testing.expectError(error.Overlap, pack(testing.allocator, base, &.{
        .{ .addr = 0x1008_0000, .bytes = &data },
        .{ .addr = 0x1008_0100, .bytes = &data },
    }));
    try testing.expectError(error.Unaligned, pack(testing.allocator, base, &.{.{ .addr = 0x1008_0010, .bytes = &data }}));
    try testing.expectError(error.EmptyRegion, pack(testing.allocator, base, &.{.{ .addr = 0x1008_0000, .bytes = &.{} }}));
    try testing.expectError(error.BadBase, pack(testing.allocator, base[0..100], &.{}));
    // Adjacent is fine.
    const out = try pack(testing.allocator, base, &.{.{ .addr = 0x1000_0200, .bytes = &data }});
    testing.allocator.free(out);
}
