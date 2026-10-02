/// The M0 test screen, generated one landscape column at a time.
///
/// Pure code (no hardware access) so `zig build test` can check it on the
/// host. Output pixels are panel wire format: big-endian RGB565 in a u16
/// (see drivers/st7789.zig).
///
/// Layout, 320x240 landscape, (x, y) from the top-left:
///   - 1 px white border on all four edges (edge and orientation check)
///   - red 16x16 square at (3, 3) and "TOP LEFT" next to it
///   - "SNOUTY TUFTY M0" at 2x
///   - 8 colour bars, white..black (y 48..111)
///   - grey ramp, black at the left to white at the right (y 112..127):
///     a smooth ramp means the byte order is right
///   - six button boxes A B C UP DN HOME, filled while held
///   - frame counter, measured fps, clock, HOME press count
const std = @import("std");
const font = @import("font").font;

pub const width = 320;
pub const height = 240;

/// Big-endian RGB565 from 8-bit channels.
pub fn rgb(r: u8, g: u8, b: u8) u16 {
    const native: u16 = (@as(u16, r & 0xF8) << 8) | (@as(u16, g & 0xFC) << 3) | (b >> 3);
    return @byteSwap(native);
}

pub const black = rgb(0, 0, 0);
pub const white = rgb(255, 255, 255);
pub const red = rgb(255, 0, 0);
pub const green = rgb(0, 255, 0);
pub const blue = rgb(0, 0, 255);
pub const yellow = rgb(255, 255, 0);
pub const cyan = rgb(0, 255, 255);
pub const magenta = rgb(255, 0, 255);
pub const grey = rgb(96, 96, 96);

const bars = [_]u16{ white, yellow, cyan, green, magenta, red, blue, black };
const bar_width = width / bars.len;
const bars_y0 = 48;
const bars_y1 = 112;
const ramp_y1 = 128;

const marker_x0 = 3;
const marker_y0 = 3;
const marker_size = 16;

pub const box_count = 6;
const box_labels = [box_count][]const u8{ "A", "B", "C", "UP", "DN", "HOME" };
const box_w = 48;
const box_gap = 4;
const box_x0 = (width - (box_count * box_w + (box_count - 1) * box_gap)) / 2;
const box_y0 = 140;
const box_y1 = 184;

/// What the screen shows this frame.
pub const State = struct {
    /// Held state of A, B, C, UP, DOWN, HOME in box order.
    held: [box_count]bool = @splat(false),
    frame: u32 = 0,
    /// Frames per second x10 (e.g. 598 = 59.8 fps).
    fps_x10: u32 = 0,
    sys_mhz: u32 = 0,
    home_presses: u32 = 0,
};

pub const Text = struct {
    x: u16,
    y: u16,
    scale: u8 = 1,
    fg: u16 = white,
    str: []const u8,
};

/// Per-frame text lines, formatted once per frame (not per column).
pub const Lines = struct {
    buf: [4][40]u8 = undefined,
    items: [8]Text = undefined,
    len: usize = 0,

    pub fn build(lines: *Lines, st: *const State) void {
        lines.len = 0;
        lines.add(.{ .x = marker_x0 + marker_size + 6, .y = 7, .str = "TOP LEFT" });
        lines.add(.{ .x = (width - 15 * 16) / 2, .y = 26, .scale = 2, .fg = yellow, .str = "SNOUTY TUFTY M0" });
        const l0 = std.fmt.bufPrint(&lines.buf[0], "FRAME {d:0>8}   FPS {d}.{d}", .{ st.frame, st.fps_x10 / 10, st.fps_x10 % 10 }) catch "";
        lines.add(.{ .x = 8, .y = 194, .str = l0 });
        const l1 = std.fmt.bufPrint(&lines.buf[1], "CLK {d} MHZ   HOME PRESSES {d}", .{ st.sys_mhz, st.home_presses }) catch "";
        lines.add(.{ .x = 8, .y = 208, .str = l1 });
        lines.add(.{ .x = 8, .y = 222, .fg = cyan, .str = "HOLD HOME 1S: REBOOT TO BOOTSEL" });
    }

    fn add(lines: *Lines, t: Text) void {
        lines.items[lines.len] = t;
        lines.len += 1;
    }
};

fn box_index(x: u16) ?usize {
    if (x < box_x0) return null;
    const rel = x - box_x0;
    const i = rel / (box_w + box_gap);
    if (i >= box_count or rel % (box_w + box_gap) >= box_w) return null;
    return i;
}

/// Draws the column of one glyph-scaled text item that falls on x
/// (`fg_override` replaces its colour). Also used by menu.zig.
pub fn text_column(t: Text, x: u16, fg_override: ?u16, out: []u16) void {
    const span: u32 = @as(u32, @intCast(t.str.len)) * 8 * t.scale;
    if (x < t.x or x >= t.x + span) return;
    const rel = (x - t.x) / t.scale;
    const ch = t.str[rel / 8];
    if (ch < ' ') return;
    const glyph = font[ch - ' '];
    const bit: u3 = @intCast(7 - rel % 8);
    const fg = fg_override orelse t.fg;
    for (0..8) |row| {
        // The SYCL font is inverted: a 0 bit is ink.
        if ((glyph[row] >> bit) & 1 != 0) continue;
        for (0..t.scale) |s| {
            const y = t.y + row * t.scale + s;
            if (y < out.len) out[y] = fg;
        }
    }
}

/// Fills out[0..240] with landscape column x (top to bottom).
pub fn render_column(x: u16, st: *const State, lines: *const Lines, out: *[height]u16) void {
    // Background, colour bars, grey ramp.
    @memset(out[0..bars_y0], black);
    @memset(out[bars_y0..bars_y1], bars[@min(x / bar_width, bars.len - 1)]);
    const g: u8 = @intCast(@as(u32, x) * 255 / (width - 1));
    @memset(out[bars_y1..ramp_y1], rgb(g, g, g));
    @memset(out[ramp_y1..], black);

    // Orientation marker.
    if (x >= marker_x0 and x < marker_x0 + marker_size)
        @memset(out[marker_y0 .. marker_y0 + marker_size], red);

    // Button boxes: 1 px outline, filled green while held, label centred.
    if (box_index(x)) |i| {
        const bx = box_x0 + i * (box_w + box_gap);
        const edge = x == bx or x == bx + box_w - 1;
        if (st.held[i]) {
            @memset(out[box_y0..box_y1], green);
        } else if (edge) {
            @memset(out[box_y0..box_y1], white);
        } else {
            out[box_y0] = white;
            out[box_y1 - 1] = white;
        }
        const label = box_labels[i];
        const label_w: u16 = @intCast(label.len * 8);
        const t: Text = .{
            .x = @intCast(bx + (box_w - label_w) / 2),
            .y = (box_y0 + box_y1) / 2 - 4,
            .str = label,
        };
        text_column(t, x, if (st.held[i]) black else white, out);
    }

    for (lines.items[0..lines.len]) |t| text_column(t, x, null, out);

    // White border last, so it is always on top.
    if (x == 0 or x == width - 1) {
        @memset(out, white);
    } else {
        out[0] = white;
        out[height - 1] = white;
    }
}

// ========================================
// Tests
// ========================================

fn test_column(x: u16, st: *const State) [height]u16 {
    var lines: Lines = .{};
    lines.build(st);
    var col: [height]u16 = undefined;
    render_column(x, st, &lines, &col);
    return col;
}

test "rgb is big-endian RGB565 on the wire" {
    // Red 0xF800 must go out as F8 00: the first byte in memory is 0xF8.
    const r = red;
    const bytes = std.mem.asBytes(&r);
    if (@import("builtin").cpu.arch.endian() == .little) {
        try std.testing.expectEqual(@as(u8, 0xF8), bytes[0]);
        try std.testing.expectEqual(@as(u8, 0x00), bytes[1]);
    }
    try std.testing.expectEqual(@as(u16, 0x001F), @byteSwap(blue));
    try std.testing.expectEqual(@as(u16, 0x07E0), @byteSwap(green));
}

test "border on every edge" {
    const st: State = .{};
    for ([_]u16{ 0, width - 1 }) |x| {
        const col = test_column(x, &st);
        for (col) |p| try std.testing.expectEqual(white, p);
    }
    for ([_]u16{ 1, 100, 318 }) |x| {
        const col = test_column(x, &st);
        try std.testing.expectEqual(white, col[0]);
        try std.testing.expectEqual(white, col[height - 1]);
    }
}

test "red marker sits at the top-left" {
    const st: State = .{};
    const col = test_column(marker_x0 + 2, &st);
    try std.testing.expectEqual(red, col[marker_y0]);
    try std.testing.expectEqual(red, col[marker_y0 + marker_size - 1]);
    try std.testing.expectEqual(black, col[marker_y0 + marker_size]);
    const far = test_column(width - 10, &st);
    try std.testing.expect(far[marker_y0 + 4] != red);
}

test "colour bars run white to black, left to right" {
    const st: State = .{};
    try std.testing.expectEqual(white, test_column(20, &st)[bars_y0 + 5]);
    try std.testing.expectEqual(red, test_column(5 * bar_width + 10, &st)[bars_y0 + 5]);
    try std.testing.expectEqual(black, test_column(width - 10, &st)[bars_y0 + 5]);
}

test "a held button fills its box" {
    var st: State = .{};
    const x = box_x0 + 2 * (box_w + box_gap) + 3; // box C, clear of its label
    try std.testing.expectEqual(black, test_column(x, &st)[box_y0 + 3]);
    st.held[2] = true;
    try std.testing.expectEqual(green, test_column(x, &st)[box_y0 + 3]);
}

test "text renders ink" {
    const st: State = .{};
    // 'T' of "TOP LEFT": its top bar spans the glyph's first row.
    const tx = marker_x0 + marker_size + 6 + 3;
    const col = test_column(tx, &st);
    var ink: usize = 0;
    for (col[7..15]) |p| {
        if (p == white) ink += 1;
    }
    try std.testing.expect(ink > 0);
}
