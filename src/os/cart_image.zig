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
};

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
