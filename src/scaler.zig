/// Cart framebuffer -> panel scaler (pure, host-tested).
///
/// A SYCL cart draws a 160x128 column-major framebuffer, `fb[x][y]`, of
/// SYCL `Pixel`s: RGB565 with *red in the low bits* (DisplayColor is
/// `packed struct { r: u5, g: u6, b: u5 }`; the SYCL panel is BGR). The
/// Tufty panel takes RGB565 with red in the high bits, big-endian on the
/// wire, and is streamed as landscape columns of 240 pixels (see
/// drivers/st7789.zig). A cart column therefore maps onto whole panel
/// columns, and only y needs a per-pixel table.
///
/// Modes (-Dscale=):
///   fit     x 2x, y 128 -> 240 nearest neighbour (no rows lost; rows are
///           drawn 1 or 2 px tall). The default.
///   crop    x 2x, y 2x, the top and bottom 4 cart rows dropped (4..123).
///   native  1:1, centred (x 80..239, y 56..183), black border.
const std = @import("std");

pub const src_w = 160;
pub const src_h = 128;
pub const dst_w = 320;
pub const dst_h = 240;

pub const Mode = enum { fit, crop, native };

/// Map entry for "no source pixel" (black).
pub const none: u8 = 0xFF;

const native_x0 = (dst_w - src_w) / 2; // 80
const native_y0 = (dst_h - src_h) / 2; // 56
const crop_rows = 4;

/// Source coordinate for every panel column (x) and row (y).
pub const Maps = struct {
    x: [dst_w]u8,
    y: [dst_h]u8,

    pub fn init(mode: Mode) Maps {
        var m: Maps = undefined;
        for (&m.x, 0..) |*sx, dx| sx.* = src_x(mode, @intCast(dx));
        for (&m.y, 0..) |*sy, dy| sy.* = src_y(mode, @intCast(dy));
        return m;
    }
};

pub fn src_x(mode: Mode, dx: u16) u8 {
    return switch (mode) {
        .fit, .crop => @intCast(dx / 2),
        .native => if (dx >= native_x0 and dx < native_x0 + src_w) @intCast(dx - native_x0) else none,
    };
}

pub fn src_y(mode: Mode, dy: u16) u8 {
    return switch (mode) {
        // Nearest neighbour on pixel centres: floor((dy + 0.5) * 128 / 240).
        .fit => @intCast((@as(u32, dy) * 2 + 1) * src_h / (2 * dst_h)),
        .crop => @intCast(crop_rows + dy / 2),
        .native => if (dy >= native_y0 and dy < native_y0 + src_h) @intCast(dy - native_y0) else none,
    };
}

/// Cart dirty rect, half-open, in cart coordinates (os_abi Rect8).
pub const Rect = struct {
    min_x: u8,
    min_y: u8,
    max_x: u8,
    max_y: u8,

    pub const all: Rect = .{ .min_x = 0, .min_y = 0, .max_x = src_w, .max_y = src_h };
};

/// Panel window, half-open, in landscape panel coordinates.
pub const Window = struct { x0: u16, x1: u16, y0: u16, y1: u16 };

/// The panel window covering every panel pixel whose source lies in
/// `rect`, or null if none does (empty rect, or rows cropped away).
/// The maps are monotonic, so a plain scan finds the bounds.
pub fn window_for(maps: *const Maps, rect: Rect) ?Window {
    const xs = span(&maps.x, rect.min_x, rect.max_x) orelse return null;
    const ys = span(&maps.y, rect.min_y, rect.max_y) orelse return null;
    return .{ .x0 = xs[0], .x1 = xs[1], .y0 = ys[0], .y1 = ys[1] };
}

fn span(map: []const u8, lo: u8, hi: u8) ?[2]u16 {
    var first: ?u16 = null;
    var last: u16 = 0;
    for (map, 0..) |s, d| {
        if (s == none or s < lo or s >= hi) continue;
        if (first == null) first = @intCast(d);
        last = @intCast(d);
    }
    return .{ first orelse return null, last + 1 };
}

/// One SYCL Pixel (red low) -> one panel wire pixel (red high, big-endian).
pub inline fn wire_pixel(p: u16) u16 {
    const rgb = (p << 11) | (p & 0x07E0) | (p >> 11);
    return @byteSwap(rgb);
}

/// Fills `out[0 .. y1 - y0]` with panel rows y0..y1 of one panel column,
/// taken from the cart column `src` (128 pixels, top to bottom).
pub fn fill_column(src: *const [src_h]u16, ymap: *const [dst_h]u8, y0: u16, y1: u16, out: []u16) void {
    for (ymap[y0..y1], out[0 .. y1 - y0]) |sy, *o| {
        o.* = if (sy == none) 0 else wire_pixel(src[sy]);
    }
}

// ========================================
// Tests
// ========================================

const testing = std.testing;

test "fit maps 128 rows onto 240, keeping every row, in order" {
    const m = Maps.init(.fit);
    try testing.expectEqual(@as(u8, 0), m.y[0]);
    try testing.expectEqual(@as(u8, 127), m.y[239]);
    var seen: [src_h]u8 = @splat(0);
    for (m.y, 0..) |sy, dy| {
        if (dy > 0) {
            try testing.expect(sy >= m.y[dy - 1]);
            try testing.expect(sy - m.y[dy - 1] <= 1);
        }
        seen[sy] += 1;
    }
    // 240 / 128 = 1.875: every cart row is drawn 1 or 2 panel rows tall.
    for (seen) |n| try testing.expect(n == 1 or n == 2);
}

test "x doubles in fit and crop" {
    for ([_]Mode{ .fit, .crop }) |mode| {
        const m = Maps.init(mode);
        try testing.expectEqual(@as(u8, 0), m.x[0]);
        try testing.expectEqual(@as(u8, 0), m.x[1]);
        try testing.expectEqual(@as(u8, 1), m.x[2]);
        try testing.expectEqual(@as(u8, 159), m.x[319]);
    }
}

test "crop drops 4 rows top and bottom" {
    const m = Maps.init(.crop);
    try testing.expectEqual(@as(u8, 4), m.y[0]);
    try testing.expectEqual(@as(u8, 4), m.y[1]);
    try testing.expectEqual(@as(u8, 123), m.y[239]);
    try testing.expectEqual(@as(?Window, null), window_for(&m, .{ .min_x = 0, .min_y = 0, .max_x = 160, .max_y = 4 }));
}

test "native centres 1:1" {
    const m = Maps.init(.native);
    try testing.expectEqual(none, m.x[79]);
    try testing.expectEqual(@as(u8, 0), m.x[80]);
    try testing.expectEqual(@as(u8, 159), m.x[239]);
    try testing.expectEqual(none, m.x[240]);
    try testing.expectEqual(none, m.y[55]);
    try testing.expectEqual(@as(u8, 0), m.y[56]);
    try testing.expectEqual(@as(u8, 127), m.y[183]);
    try testing.expectEqual(none, m.y[184]);
    try testing.expectEqual(Window{ .x0 = 80, .x1 = 240, .y0 = 56, .y1 = 184 }, window_for(&m, .all).?);
}

test "windows for full and dirty rects" {
    const m = Maps.init(.fit);
    try testing.expectEqual(Window{ .x0 = 0, .x1 = 320, .y0 = 0, .y1 = 240 }, window_for(&m, .all).?);
    const w = window_for(&m, .{ .min_x = 10, .min_y = 64, .max_x = 11, .max_y = 65 }).?;
    try testing.expectEqual(@as(u16, 20), w.x0);
    try testing.expectEqual(@as(u16, 22), w.x1);
    for (w.y0..w.y1) |dy| try testing.expectEqual(@as(u8, 64), m.y[dy]);
    try testing.expect(m.y[w.y0 - 1] == 63 and m.y[w.y1] == 65);
    // Empty rect (Rect8.none: min > max).
    try testing.expectEqual(@as(?Window, null), window_for(&m, .{ .min_x = 160, .min_y = 128, .max_x = 0, .max_y = 0 }));
}

test "wire pixel swaps red/blue and emits big-endian" {
    // SYCL red: r field (low 5 bits) = 31.
    const sycl_red: u16 = 0x001F;
    const sycl_green: u16 = 0x07E0;
    const sycl_blue: u16 = 0xF800;
    // Panel RGB565: red 0xF800, green 0x07E0, blue 0x001F; bytes high first.
    try testing.expectEqual(@as(u16, 0xF800), @byteSwap(wire_pixel(sycl_red)));
    try testing.expectEqual(@as(u16, 0x07E0), @byteSwap(wire_pixel(sycl_green)));
    try testing.expectEqual(@as(u16, 0x001F), @byteSwap(wire_pixel(sycl_blue)));
    const w = wire_pixel(sycl_red);
    try testing.expectEqual(@as(u8, 0xF8), std.mem.asBytes(&w)[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), wire_pixel(0xFFFF));
}

test "fill_column follows the row map" {
    const m = Maps.init(.fit);
    var src: [src_h]u16 = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast(i); // blue-ish ramp, distinct values
    var out: [dst_h]u16 = undefined;
    fill_column(&src, &m.y, 0, dst_h, &out);
    for (out, 0..) |o, dy| try testing.expectEqual(wire_pixel(src[m.y[dy]]), o);
    // A sub-window lands at out[0].
    fill_column(&src, &m.y, 100, 110, &out);
    try testing.expectEqual(wire_pixel(src[m.y[100]]), out[0]);
}
