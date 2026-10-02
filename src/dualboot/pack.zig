//! Dual-boot UF2 packing (docs/DUALBOOT.md). Pure, host-tested; the file
//! I/O is in tools/dualboot_uf2.zig.
//!
//!   image_from_elf  the arcade's flash bytes from its ELF (linked at the
//!                   0x10000000 runtime address), by program header
//!   check_image     vector table + IMAGE_DEF, as chain_image() will see them
//!   check_stub      the launch stub's vector table and IMAGE_DEF
//!   pack            launcher sector + window image -> UF2 blocks at the
//!                   physical addresses 0x1014F000..0x10200000
const std = @import("std");
const layout = @import("layout.zig");

pub const family_rp2350_arm_s: u32 = 0xe48b_ff59;
const uf2_magic0: u32 = 0x0A32_4655;
const uf2_magic1: u32 = 0x9E5D_5157;
const uf2_magic_end: u32 = 0x0AB1_6F30;
const uf2_flag_family: u32 = 0x0000_2000;
pub const payload: u32 = 256;
/// XIP chip select 0: where an ELF segment's load address may be.
const flash_window: u32 = 16 * 1024 * 1024;

/// The IMAGE_DEF item both images carry: EXE, Secure, Arm, RP2350, no TBYB
/// (microzig bootmeta.zig; stub.S).
pub const image_type_item: u32 = 0x1021_0142;
const block_start: u32 = 0xffff_ded3;
const block_end: u32 = 0xab12_3579;
const last_item_one_word: u32 = 0x0000_01ff;

pub const Error = error{
    BadElf,
    SegmentOutsideWindow,
    ImageEmpty,
    ImageTooLarge,
    BadStackPointer,
    BadResetVector,
    NoImageDef,
    BadImageDef,
    StubTooLarge,
    BadStub,
} || std.mem.Allocator.Error;

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

/// The flash bytes (from the runtime base) out of a 32-bit little-endian
/// Arm ELF: every PT_LOAD with file bytes goes at its physical (load)
/// address, which must be in the 16 MB flash window from the runtime base
/// (anything else, e.g. file bytes loaded to RAM, is SegmentOutsideWindow).
/// The result may be longer than the dual-boot window: check_image refuses
/// that with the exact size. Gaps between segments are 0xFF (erased flash).
pub fn image_from_elf(gpa: std.mem.Allocator, elf: []const u8) Error![]u8 {
    if (elf.len < 52 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 1 or elf[5] != 1) return error.BadElf;
    if (rd16(elf, 18) != 40) return error.BadElf; // EM_ARM
    const phoff = rd32(elf, 28);
    const phentsize = rd16(elf, 42);
    const phnum = rd16(elf, 44);
    if (phentsize < 32 or phoff + @as(usize, phentsize) * phnum > elf.len) return error.BadElf;

    var end: u32 = 0;
    for (0..phnum) |i| {
        const ph = elf[phoff + i * phentsize ..];
        if (rd32(ph, 0) != 1) continue; // PT_LOAD
        const offset = rd32(ph, 4);
        const paddr = rd32(ph, 12);
        const filesz = rd32(ph, 16);
        if (filesz == 0) continue;
        if (@as(u64, offset) + filesz > elf.len) return error.BadElf;
        if (paddr < layout.runtime_base or @as(u64, paddr) + filesz > layout.runtime_base + @as(u64, flash_window))
            return error.SegmentOutsideWindow;
        end = @max(end, paddr - layout.runtime_base + filesz);
    }
    if (end == 0) return error.ImageEmpty;

    const image = try gpa.alloc(u8, end);
    @memset(image, 0xFF);
    for (0..phnum) |i| {
        const ph = elf[phoff + i * phentsize ..];
        if (rd32(ph, 0) != 1 or rd32(ph, 16) == 0) continue;
        const at = rd32(ph, 12) - layout.runtime_base;
        const n = rd32(ph, 16);
        @memcpy(image[at .. at + n], elf[rd32(ph, 4)..][0..n]);
    }
    return image;
}

pub const ImageInfo = struct {
    initial_sp: u32,
    reset: u32,
    /// Offset of the IMAGE_DEF block in the image.
    image_def_at: u32,
};

/// Finds the first block marker in the first 4 KB (the bootrom's search
/// limit, datasheet 5.1.5) and checks it is our single-item IMAGE_DEF
/// block linking to itself.
fn find_image_def(bytes: []const u8) Error!u32 {
    var off: u32 = 0;
    while (off + 20 <= @min(bytes.len, layout.sector)) : (off += 4) {
        if (rd32(bytes, off) != block_start) continue;
        if (rd32(bytes, off + 4) != image_type_item or rd32(bytes, off + 8) != last_item_one_word or
            rd32(bytes, off + 12) != 0 or rd32(bytes, off + 16) != block_end) return error.BadImageDef;
        return off;
    }
    return error.NoImageDef;
}

/// The arcade image as chain_image() enters it: the vector table at the
/// window start (no VECTOR_TABLE item, so the default), SP in SRAM, the
/// reset handler a Thumb address inside the image, an IMAGE_DEF in the
/// first 4 KB.
pub fn check_image(image: []const u8) Error!ImageInfo {
    if (image.len < 8) return error.ImageEmpty;
    if (image.len > layout.window_size) return error.ImageTooLarge;
    const sp = rd32(image, 0);
    const reset = rd32(image, 4);
    if (sp <= layout.sram_base or sp > layout.stub_stack_top or sp % 8 != 0) return error.BadStackPointer;
    if (reset & 1 == 0 or reset < layout.runtime_base or reset - layout.runtime_base >= image.len) return error.BadResetVector;
    return .{ .initial_sp = sp, .reset = reset, .image_def_at = try find_image_def(image) };
}

/// The stub (stub.S, linked at 0): SP = the SCRATCH_Y top, three Thumb
/// handler offsets inside the stub, the IMAGE_DEF block at 0x10.
pub fn check_stub(stub: []const u8) Error!void {
    if (stub.len > layout.stub_max) return error.StubTooLarge;
    if (stub.len < 36 or stub.len % 4 != 0) return error.BadStub;
    if (rd32(stub, 0) != layout.stub_stack_top) return error.BadStub;
    for (1..4) |i| {
        const v = rd32(stub, i * 4);
        if (v & 1 == 0 or v >= stub.len) return error.BadStub;
    }
    if ((find_image_def(stub) catch return error.BadStub) != 16) return error.BadStub;
}

/// The launcher sector's bytes: header, then the stub.
pub fn launcher_bytes(gpa: std.mem.Allocator, stub: []const u8, image: []const u8) Error![]u8 {
    try check_stub(stub);
    const h: layout.Header = .{
        .stub_len = @intCast(stub.len),
        .stub_crc = layout.crc32(stub),
        .image_len = @intCast(image.len),
        .image_crc = layout.crc32(image),
    };
    const out = try gpa.alloc(u8, layout.stub_offset + stub.len);
    @memcpy(out[0..layout.stub_offset], &h.encode());
    @memcpy(out[layout.stub_offset..], stub);
    return out;
}

fn blocks_for(n: usize) u32 {
    return @intCast((n + payload - 1) / payload);
}

fn put_block(out: []u8, no: u32, total: u32, addr: u32, data: []const u8) void {
    std.debug.assert(out.len == 512 and data.len <= payload);
    @memset(out, 0);
    const w = struct {
        fn f(o: []u8, off: usize, v: u32) void {
            std.mem.writeInt(u32, o[off..][0..4], v, .little);
        }
    }.f;
    w(out, 0, uf2_magic0);
    w(out, 4, uf2_magic1);
    w(out, 8, uf2_flag_family);
    w(out, 12, addr);
    w(out, 16, payload);
    w(out, 20, no);
    w(out, 24, total);
    w(out, 28, family_rp2350_arm_s);
    @memset(out[32 .. 32 + payload], 0xFF);
    @memcpy(out[32..][0..data.len], data);
    w(out, 508, uf2_magic_end);
}

/// The dual-boot UF2: the launcher sector at 0x1014F000, then the image at
/// the window base. Every block is 256 bytes of RP2350_ARM_S main flash; a
/// short last block is padded with 0xFF.
pub fn pack(gpa: std.mem.Allocator, launcher: []const u8, image: []const u8) Error![]u8 {
    if (launcher.len > layout.sector) return error.StubTooLarge;
    if (image.len > layout.window_size) return error.ImageTooLarge;
    const nl = blocks_for(launcher.len);
    const ni = blocks_for(image.len);
    const total = nl + ni;
    const out = try gpa.alloc(u8, @as(usize, total) * 512);
    for (0..nl) |i| {
        const from = i * payload;
        put_block(out[i * 512 ..][0..512], @intCast(i), total, layout.launcher_sector + @as(u32, @intCast(from)), launcher[from..@min(launcher.len, from + payload)]);
    }
    for (0..ni) |i| {
        const from = i * payload;
        const no: u32 = nl + @as(u32, @intCast(i));
        put_block(out[no * 512 ..][0..512], no, total, layout.window_base + @as(u32, @intCast(from)), image[from..@min(image.len, from + payload)]);
    }
    return out;
}

// ========================================
// Tests
// ========================================

const testing = std.testing;
const uf2_check = @import("../uf2_check.zig");

fn fake_image(gpa: std.mem.Allocator, len: usize) ![]u8 {
    const img = try gpa.alloc(u8, len);
    for (img, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    std.mem.writeInt(u32, img[0..4], 0x2002_0000, .little);
    std.mem.writeInt(u32, img[4..8], 0x1000_0201, .little);
    const blk = [_]u32{ block_start, image_type_item, last_item_one_word, 0, block_end };
    for (blk, 0..) |w, i| std.mem.writeInt(u32, img[0x110 + i * 4 ..][0..4], w, .little);
    return img;
}

fn fake_stub(gpa: std.mem.Allocator) ![]u8 {
    const s = try gpa.alloc(u8, 64);
    @memset(s, 0);
    const words = [_]u32{ layout.stub_stack_top, 0x25, 0x31, 0x31, block_start, image_type_item, last_item_one_word, 0, block_end };
    for (words, 0..) |w, i| std.mem.writeInt(u32, s[i * 4 ..][0..4], w, .little);
    return s;
}

test "pack puts every block inside the gap, launcher first" {
    const gpa = testing.allocator;
    const img = try fake_image(gpa, 600_001);
    defer gpa.free(img);
    const stub = try fake_stub(gpa);
    defer gpa.free(stub);

    const info = try check_image(img);
    try testing.expectEqual(@as(u32, 0x110), info.image_def_at);

    const launcher = try launcher_bytes(gpa, stub, img);
    defer gpa.free(launcher);
    const uf2 = try pack(gpa, launcher, img);
    defer gpa.free(uf2);

    const s = uf2_check.check_range(uf2, layout.gap_start, layout.gap_end).ok;
    try testing.expectEqual(layout.gap_start, s.lo);
    try testing.expectEqual(layout.window_base + 2344 * 256, s.hi); // 600001 bytes -> 2344 blocks
    try testing.expectEqual(@as(u32, 1 + 2344), s.blocks);
    // The same UF2 is refused by the normal arcade's range (it starts at 0x10000000
    // there, but nothing of the dual-boot build may be below the gap).
    try testing.expectEqual(uf2_check.Problem.below_start, uf2_check.check_range(uf2, layout.gap_start + 0x1000, layout.gap_end).bad.problem);

    // Round trip: flash contents == launcher sector + image.
    const flash = try gpa.alloc(u8, layout.gap_end - layout.gap_start);
    defer gpa.free(flash);
    @memset(flash, 0xFF);
    uf2_check.flatten(uf2, layout.gap_start, flash);
    try testing.expectEqualSlices(u8, launcher, flash[0..launcher.len]);
    try testing.expectEqualSlices(u8, img, flash[layout.sector..][0..img.len]);
    const h = layout.Header.decode(flash[0..layout.stub_offset]).?;
    try testing.expectEqual(@as(u32, 64), h.stub_len);
    try testing.expectEqual(layout.crc32(stub), h.stub_crc);
    try testing.expectEqual(layout.crc32(img), h.image_crc);
}

test "an image over the window or with a bad vector table is refused" {
    const gpa = testing.allocator;
    const big = try fake_image(gpa, layout.window_size + 1);
    defer gpa.free(big);
    try testing.expectError(error.ImageTooLarge, check_image(big));
    const img = try fake_image(gpa, 4096);
    defer gpa.free(img);
    std.mem.writeInt(u32, img[4..8], 0x1000_0200, .little); // no Thumb bit
    try testing.expectError(error.BadResetVector, check_image(img));
    std.mem.writeInt(u32, img[4..8], 0x1000_2001, .little); // past the image
    try testing.expectError(error.BadResetVector, check_image(img));
    std.mem.writeInt(u32, img[4..8], 0x1000_0201, .little);
    std.mem.writeInt(u32, img[0..4], 0x1000_0000, .little); // SP not in SRAM
    try testing.expectError(error.BadStackPointer, check_image(img));
    std.mem.writeInt(u32, img[0..4], 0x2002_0000, .little);
    std.mem.writeInt(u32, img[0x114..][0..4], 0x1011_0142, .little); // Non-secure IMAGE_DEF
    try testing.expectError(error.BadImageDef, check_image(img));
}

test "image_from_elf places segments by load address and refuses anything outside the window" {
    const gpa = testing.allocator;
    // ELF header + 3 program headers + data.
    var elf: [52 + 3 * 32 + 16]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 1; // 32-bit
    elf[5] = 1; // little-endian
    std.mem.writeInt(u16, elf[18..20], 40, .little);
    std.mem.writeInt(u32, elf[28..32], 52, .little);
    std.mem.writeInt(u16, elf[42..44], 32, .little);
    std.mem.writeInt(u16, elf[44..46], 3, .little);
    const data_at = 52 + 3 * 32;
    @memcpy(elf[data_at..][0..16], "ABCDEFGHIJKLMNOP");
    const ph = struct {
        fn set(e: []u8, i: usize, typ: u32, off: u32, vaddr: u32, paddr: u32, filesz: u32) void {
            const p = e[52 + i * 32 ..];
            std.mem.writeInt(u32, p[0..4], typ, .little);
            std.mem.writeInt(u32, p[4..8], off, .little);
            std.mem.writeInt(u32, p[8..12], vaddr, .little);
            std.mem.writeInt(u32, p[12..16], paddr, .little);
            std.mem.writeInt(u32, p[16..20], filesz, .little);
            std.mem.writeInt(u32, p[20..24], filesz, .little);
        }
    }.set;
    ph(&elf, 0, 1, data_at, 0x1000_0000, 0x1000_0000, 8); // .text
    ph(&elf, 1, 1, data_at + 8, 0x2000_0000, 0x1000_0010, 8); // .data: RAM VMA, flash LMA
    ph(&elf, 2, 1, 0, 0x2000_0100, 0x2000_0100, 0); // .bss: no file bytes
    const img = try image_from_elf(gpa, &elf);
    defer gpa.free(img);
    try testing.expectEqualSlices(u8, "ABCDEFGH\xff\xff\xff\xff\xff\xff\xff\xffIJKLMNOP", img);

    ph(&elf, 1, 1, data_at + 8, 0x2000_0000, 0x2000_0000, 8); // file bytes in RAM: refused
    try testing.expectError(error.SegmentOutsideWindow, image_from_elf(gpa, &elf));
    ph(&elf, 1, 1, data_at + 8, 0x0FFF_FFFC, 0x0FFF_FFFC, 8); // below flash
    try testing.expectError(error.SegmentOutsideWindow, image_from_elf(gpa, &elf));
    ph(&elf, 1, 1, data_at + 8, 0x100B_0000, 0x100B_0000 - 4, 8); // crosses the window end: the image says by how much
    const long = try image_from_elf(gpa, &elf);
    defer gpa.free(long);
    try testing.expectEqual(@as(usize, layout.window_size + 4), long.len);
    try testing.expectError(error.ImageTooLarge, check_image(long));
}

test "check_stub wants the SCRATCH_Y stack and the IMAGE_DEF at 0x10" {
    const gpa = testing.allocator;
    const stub = try fake_stub(gpa);
    defer gpa.free(stub);
    try check_stub(stub);
    std.mem.writeInt(u32, stub[4..8], 0x24, .little);
    try testing.expectError(error.BadStub, check_stub(stub));
}
