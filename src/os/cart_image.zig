/// Validation of an embedded RAM-cart image (pure, host-tested).
///
/// The image is the cart ELF's loadable bytes (objcopy -O binary), which
/// starts at the cart's link address, abi.cart_ram_origin. The rules mirror
/// sycl-badge src/os/loader/loader.zig: the cart descriptor (CART_MAGIC) is
/// found in the first UF2 block's worth of bytes, version V1, BSS inside
/// cart RAM, and an entry point (Thumb) inside the image.
const std = @import("std");
const abi = @import("abi.zig");

pub const Info = struct {
    /// Address of the cart descriptor in cart RAM.
    descriptor_addr: u32,
    bss_start: u32,
    bss_end: u32,
    /// Thumb entry address (odd).
    entry_point: u32,
};

pub const Error = error{
    ImageTooLarge,
    NoDescriptor,
    BadVersion,
    BadBss,
    BadEntry,
    // XIP carts (validate_xip, and the boot-time CRC checks in cart_host.zig).
    /// The cart window holds erased (0xFF) or zeroed flash: no XIP image.
    NoXipImage,
    /// The vector table's initial SP is unaligned or outside cart RAM.
    BadStack,
    /// The cart window's bytes differ from the image the build packed.
    XipMismatch,
    /// The drive region's bytes differ from the drive image the build packed.
    DriveMismatch,
};

/// The SYCL cart flash window (sycl-badge src/cart/cart_xip.ld FLASH,
/// src/os/linker.ld cart_xip at a6ce19f).
pub const xip_window_start: u32 = 0x101C_0000;
pub const xip_window_end: u32 = 0x1020_0000;

pub const XipInfo = struct {
    /// Where the vector table is (VTOR for core 1).
    vector_table: u32,
    initial_sp: u32,
    /// Thumb entry address (odd).
    entry_point: u32,
};

/// Checks an XIP cart's vector table (its first two words, `[SP, reset]`),
/// with the rules of the SYCL OS's executeCart (sycl-badge src/os/cart.zig):
/// SP 8-byte aligned and inside cart RAM above the IPC block, the reset
/// handler a Thumb address inside the window.
pub fn validate_xip(vector: [2]u32) Error!XipInfo {
    const sp = vector[0];
    const entry = vector[1];
    if ((sp == 0xFFFF_FFFF and entry == 0xFFFF_FFFF) or (sp == 0 and entry == 0)) return error.NoXipImage;
    if (sp & 7 != 0 or sp <= abi.cart_ram_origin or sp > abi.process_ram_end) return error.BadStack;
    const entry_even = entry & ~@as(u32, 1);
    if (entry & 1 == 0 or entry_even < xip_window_start or entry_even >= xip_window_end) return error.BadEntry;
    return .{ .vector_table = xip_window_start, .initial_sp = sp, .entry_point = entry };
}

/// Search window for the descriptor: the payload of the first UF2 block,
/// which is where the SYCL loader looks.
const search_bytes = 256;

pub fn validate(image: []const u8, load_addr: u32) Error!Info {
    if (image.len > abi.process_ram_end - load_addr) return error.ImageTooLarge;

    const window = image[0 .. @min(image.len, search_bytes) & ~@as(usize, 3)];
    var off: usize = 0;
    const desc_off = while (off + @sizeOf(abi.CartDescriptorV1) <= window.len) : (off += 4) {
        if (std.mem.readInt(u32, image[off..][0..4], .little) == abi.CART_MAGIC) break off;
    } else return error.NoDescriptor;

    const d = std.mem.bytesToValue(abi.CartDescriptorV1, image[desc_off..][0..@sizeOf(abi.CartDescriptorV1)]);
    if (d.version != abi.CART_VERSION_V1) return error.BadVersion;

    const image_end = load_addr + @as(u32, @intCast(image.len));
    if (d.bss_start > d.bss_end or d.bss_start < load_addr or d.bss_end > abi.process_ram_end)
        return error.BadBss;

    const entry_even = d.entry_point & ~@as(u32, 1);
    if (d.entry_point & 1 == 0 or entry_even < load_addr or entry_even >= image_end)
        return error.BadEntry;

    return .{
        .descriptor_addr = load_addr + @as(u32, @intCast(desc_off)),
        .bss_start = d.bss_start,
        .bss_end = d.bss_end,
        .entry_point = d.entry_point,
    };
}

// ========================================
// Tests
// ========================================

fn fake_image(buf: []u8, version: u32, bss: [2]u32, entry: u32) []u8 {
    @memset(buf, 0);
    const d: abi.CartDescriptorV1 = .{
        .magic = abi.CART_MAGIC,
        .version = version,
        .bss_start = bss[0],
        .bss_end = bss[1],
        .entry_point = entry,
    };
    @memcpy(buf[0..@sizeOf(abi.CartDescriptorV1)], std.mem.asBytes(&d));
    return buf;
}

test "accepts a well-formed image" {
    var buf: [1024]u8 = undefined;
    const base = abi.cart_ram_origin;
    const img = fake_image(&buf, abi.CART_VERSION_V1, .{ base + 1024, base + 4096 }, base + 0x41);
    const info = try validate(img, base);
    try std.testing.expectEqual(base, info.descriptor_addr);
    try std.testing.expectEqual(base + 0x41, info.entry_point);
}

test "rejects bad images" {
    var buf: [1024]u8 = undefined;
    const base = abi.cart_ram_origin;
    try std.testing.expectError(error.BadVersion, validate(fake_image(&buf, 1, .{ base + 1024, base + 4096 }, base + 0x41), base));
    try std.testing.expectError(error.BadBss, validate(fake_image(&buf, abi.CART_VERSION_V1, .{ base + 4096, base + 1024 }, base + 0x41), base));
    try std.testing.expectError(error.BadBss, validate(fake_image(&buf, abi.CART_VERSION_V1, .{ base, abi.process_ram_end + 4 }, base + 0x41), base));
    try std.testing.expectError(error.BadEntry, validate(fake_image(&buf, abi.CART_VERSION_V1, .{ base + 1024, base + 4096 }, base + 0x40), base));
    try std.testing.expectError(error.BadEntry, validate(fake_image(&buf, abi.CART_VERSION_V1, .{ base + 1024, base + 4096 }, base + 0x10001), base));
    @memset(&buf, 0);
    try std.testing.expectError(error.NoDescriptor, validate(&buf, base));
}

test "XIP vector tables" {
    // What build/xip/entry.zig emits: __stack_top__ = 0x20080000, reset in the window.
    const ok = try validate_xip(.{ 0x2008_0000, 0x101C_0101 });
    try std.testing.expectEqual(@as(u32, 0x101C_0000), ok.vector_table);
    try std.testing.expectEqual(@as(u32, 0x2008_0000), ok.initial_sp);
    try std.testing.expectEqual(@as(u32, 0x101C_0101), ok.entry_point);
    try std.testing.expectError(error.NoXipImage, validate_xip(.{ 0xFFFF_FFFF, 0xFFFF_FFFF }));
    try std.testing.expectError(error.NoXipImage, validate_xip(.{ 0, 0 }));
    try std.testing.expectError(error.BadStack, validate_xip(.{ 0x2008_0004, 0x101C_0101 }));
    try std.testing.expectError(error.BadStack, validate_xip(.{ 0x2008_0008, 0x101C_0101 }));
    try std.testing.expectError(error.BadStack, validate_xip(.{ abi.cart_ram_origin, 0x101C_0101 }));
    try std.testing.expectError(error.BadEntry, validate_xip(.{ 0x2008_0000, 0x101C_0100 }));
    try std.testing.expectError(error.BadEntry, validate_xip(.{ 0x2008_0000, 0x1020_0001 }));
    try std.testing.expectError(error.BadEntry, validate_xip(.{ 0x2008_0000, 0x1000_0101 }));
}
