/// UF2 flash budget check (pure, host-tested), used by tools/flash_check.zig
/// after every cart-host firmware build.
///
/// A firmware UF2 passes when every block is a main-flash block of family
/// RP2350_ARM_S, inside 0x10000000..limit. With limit = 0x101C0000 that
/// keeps 0x101C0000..0x10200000 free for a future XIP cart, the badge's
/// ROMFS (0x10200000) and FAT drive untouched, and rules out an absolute
/// block at 0x10ffff00.
const std = @import("std");

pub const block_size = 512;
pub const payload_max = 476;
pub const flash_base: u32 = 0x1000_0000;
pub const family_rp2350_arm_s: u32 = 0xe48b_ff59;

const magic_start0: u32 = 0x0A32_4655;
const magic_start1: u32 = 0x9E5D_5157;
const magic_end: u32 = 0x0AB1_6F30;
const flag_not_main_flash: u32 = 0x0000_0001;
const flag_family_present: u32 = 0x0000_2000;

pub const Block = struct {
    flags: u32,
    addr: u32,
    size: u32,
    family: u32,
    data: []const u8,
};

pub const Problem = enum {
    not_block_aligned,
    bad_magic,
    bad_payload_size,
    not_main_flash,
    no_family,
    wrong_family,
    below_flash,
    past_limit,

    pub fn text(p: Problem) []const u8 {
        return switch (p) {
            .not_block_aligned => "file size is not a multiple of 512",
            .bad_magic => "bad UF2 magic",
            .bad_payload_size => "payload size over 476 bytes",
            .not_main_flash => "block is flagged not-main-flash",
            .no_family => "block has no family ID",
            .wrong_family => "family is not RP2350_ARM_S (0xe48bff59)",
            .below_flash => "target below flash (0x10000000)",
            .past_limit => "target reaches the flash limit",
        };
    }
};

pub const Summary = struct {
    blocks: u32 = 0,
    /// Lowest and one-past-highest target address.
    lo: u32 = 0xFFFF_FFFF,
    hi: u32 = 0,
    /// Sum of the payload sizes.
    payload: u32 = 0,
};

pub const Result = union(enum) {
    ok: Summary,
    bad: struct { block: u32, addr: u32, end: u32, problem: Problem },
};

fn word(blk: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, blk[off..][0..4], .little);
}

pub fn parse_block(blk: *const [block_size]u8) ?Block {
    if (word(blk, 0) != magic_start0 or word(blk, 4) != magic_start1 or word(blk, 508) != magic_end) return null;
    const size = word(blk, 16);
    return .{
        .flags = word(blk, 8),
        .addr = word(blk, 12),
        .size = size,
        .family = word(blk, 28),
        .data = blk[32 .. 32 + @min(size, payload_max)],
    };
}

/// Checks every block of `uf2` against `limit` (exclusive end address).
pub fn check(uf2: []const u8, limit: u32) Result {
    if (uf2.len == 0 or uf2.len % block_size != 0) return .{ .bad = .{ .block = 0, .addr = 0, .end = 0, .problem = .not_block_aligned } };
    var s: Summary = .{};
    var i: u32 = 0;
    while (i * block_size < uf2.len) : (i += 1) {
        const raw = uf2[i * block_size ..][0..block_size];
        const blk = parse_block(raw) orelse return .{ .bad = .{ .block = i, .addr = 0, .end = 0, .problem = .bad_magic } };
        const end = blk.addr +| blk.size;
        const problem: ?Problem = if (blk.size > payload_max)
            .bad_payload_size
        else if (blk.flags & flag_not_main_flash != 0)
            .not_main_flash
        else if (blk.flags & flag_family_present == 0)
            .no_family
        else if (blk.family != family_rp2350_arm_s)
            .wrong_family
        else if (blk.addr < flash_base)
            .below_flash
        else if (end > limit)
            .past_limit
        else
            null;
        if (problem) |p| return .{ .bad = .{ .block = i, .addr = blk.addr, .end = end, .problem = p } };
        s.blocks += 1;
        s.lo = @min(s.lo, blk.addr);
        s.hi = @max(s.hi, end);
        s.payload += blk.size;
    }
    return .{ .ok = s };
}

/// Writes the payloads of a checked UF2 into `image` (flash bytes from
/// `base`, gaps left as they are).
pub fn flatten(uf2: []const u8, base: u32, image: []u8) void {
    var off: usize = 0;
    while (off + block_size <= uf2.len) : (off += block_size) {
        const blk = parse_block(uf2[off..][0..block_size]) orelse continue;
        const at = blk.addr - base;
        @memcpy(image[at .. at + blk.data.len], blk.data);
    }
}

/// The flash address of `blob` inside `image` (based at `base`), if it is
/// there, and whether it is there exactly once.
pub fn locate(image: []const u8, base: u32, blob: []const u8) ?struct { addr: u32, unique: bool } {
    const first = std.mem.indexOf(u8, image, blob) orelse return null;
    const again = std.mem.indexOfPos(u8, image, first + 1, blob) != null;
    return .{ .addr = base + @as(u32, @intCast(first)), .unique = !again };
}

// ========================================
// Tests
// ========================================

fn make_block(out: *[block_size]u8, addr: u32, size: u32, family: u32, flags: u32, fill: u8) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], magic_start0, .little);
    std.mem.writeInt(u32, out[4..8], magic_start1, .little);
    std.mem.writeInt(u32, out[8..12], flags, .little);
    std.mem.writeInt(u32, out[12..16], addr, .little);
    std.mem.writeInt(u32, out[16..20], size, .little);
    std.mem.writeInt(u32, out[28..32], family, .little);
    @memset(out[32 .. 32 + @min(size, payload_max)], fill);
    std.mem.writeInt(u32, out[508..512], magic_end, .little);
}

test "a firmware below the limit passes and is summarised" {
    var uf2: [2 * block_size]u8 = undefined;
    make_block(uf2[0..block_size], 0x1000_0000, 256, family_rp2350_arm_s, flag_family_present, 0xAA);
    make_block(uf2[block_size..][0..block_size], 0x1000_0100, 256, family_rp2350_arm_s, flag_family_present, 0xBB);
    const s = check(&uf2, 0x101C_0000).ok;
    try std.testing.expectEqual(@as(u32, 2), s.blocks);
    try std.testing.expectEqual(@as(u32, 0x1000_0000), s.lo);
    try std.testing.expectEqual(@as(u32, 0x1000_0200), s.hi);

    var image: [512]u8 = @splat(0);
    flatten(&uf2, 0x1000_0000, &image);
    const blob: [4]u8 = .{ 0xAA, 0xAA, 0xBB, 0xBB };
    const at = locate(&image, 0x1000_0000, &blob).?;
    try std.testing.expectEqual(@as(u32, 0x1000_00FE), at.addr);
    try std.testing.expect(at.unique);
    try std.testing.expect(locate(&image, 0x1000_0000, &.{ 0xBB, 0xAA }) == null);
}

test "the limit, the family and the 0x10ffff00 block are enforced" {
    var uf2: [block_size]u8 = undefined;
    // Ends exactly at the limit: fine. One byte past: refused.
    make_block(&uf2, 0x101B_FF00, 256, family_rp2350_arm_s, flag_family_present, 0);
    try std.testing.expect(check(&uf2, 0x101C_0000) == .ok);
    make_block(&uf2, 0x101B_FF01, 256, family_rp2350_arm_s, flag_family_present, 0);
    try std.testing.expectEqual(Problem.past_limit, check(&uf2, 0x101C_0000).bad.problem);
    // The picotool "absolute" block.
    make_block(&uf2, 0x10FF_FF00, 256, family_rp2350_arm_s, flag_family_present, 0);
    try std.testing.expectEqual(Problem.past_limit, check(&uf2, 0x101C_0000).bad.problem);
    make_block(&uf2, 0x1000_0000, 256, 0xe48b_ff57, flag_family_present, 0);
    try std.testing.expectEqual(Problem.wrong_family, check(&uf2, 0x101C_0000).bad.problem);
    make_block(&uf2, 0x1000_0000, 256, family_rp2350_arm_s, 0, 0);
    try std.testing.expectEqual(Problem.no_family, check(&uf2, 0x101C_0000).bad.problem);
    try std.testing.expectEqual(Problem.not_block_aligned, check(uf2[0..100], 0x101C_0000).bad.problem);
}
