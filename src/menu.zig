/// The arcade boot menu, generated one landscape column at a time (pure,
/// host-tested, and rendered to docs/arcade-menu.png by tools/menu_png.zig).
///
/// Like pattern.zig it needs no framebuffer: cart_host streams 320 columns
/// of 240 pixels through two column buffers. Output pixels are panel wire
/// format (big-endian RGB565, see drivers/st7789.zig).
///
/// Layout, 320x240 landscape, Antithesis brand colours (snouty-run's panel:
/// anti-black 0x16031B, anti-white 0xFCFBF9, coral 0xF18271):
///   y   8..56   Iris mark (2x) + "SNOUTY" / "ARCADE" (3x)
///   y  64..66   coral rule
///   y  72..182  up to 5 cart rows (2x titles), the cursor row in coral;
///               the list scrolls to keep the cursor visible
///   y 188..196  the highlighted cart's controls blurb, and "n/N"
///   y 204       thin rule
///   y 212..232  the menu controls, two lines
const std = @import("std");
const pattern = @import("pattern.zig");
const iris = @import("iris_mark");

pub const width = pattern.width;
pub const height = pattern.height;

const rgb = pattern.rgb;
pub const bg = rgb(0x16, 0x03, 0x1B);
pub const fg = rgb(0xFC, 0xFB, 0xF9);
pub const coral = rgb(0xF1, 0x82, 0x71);
pub const dim = rgb(0x8E, 0x7C, 0x96);
pub const row_bg = rgb(0x26, 0x12, 0x2C);
pub const rule_dim = rgb(0x3A, 0x26, 0x40);

const iris_scale = 2;
const iris_px = iris.size * iris_scale; // 48
const header_y = 8;
const word_scale = 3;
const header_w = iris_px + 12 + 6 * 8 * word_scale; // mark, gap, "SNOUTY"
const header_x = (width - header_w) / 2;
const word_x = header_x + iris_px + 12;

const rule_y = 64;
const rule_h = 2;
const margin_x = 8;

pub const list_y = 72;
pub const row_h = 22;
const box_h = 20;
pub const visible_rows = 5;

const blurb_y = 188;
const thin_rule_y = 204;
const footer_y0 = 212;
const footer_y1 = 224;

/// Longest title drawn at 2x (16 px per character inside the row box);
/// longer ones drop to 1x.
pub const max_title_2x = (width - 2 * margin_x - 2 * 8) / 16; // 18
/// Longest blurb (room is left for the "n/N" counter).
pub const max_blurb = 32;

/// What the menu shows.
pub const View = struct {
    titles: []const []const u8,
    /// Per cart, "" for none.
    blurbs: []const []const u8,
    cursor: u8 = 0,
    /// Bit i set: cart i can launch (a bad image is drawn dimmed).
    playable: u32 = 0xFFFF_FFFF,

    pub fn first_visible(v: *const View) u8 {
        return if (v.cursor < visible_rows) 0 else v.cursor - (visible_rows - 1);
    }

    fn is_playable(v: *const View, i: usize) bool {
        return v.playable & (@as(u32, 1) << @intCast(i)) != 0;
    }
};

const Text = pattern.Text;

/// Text items, laid out once per redraw (not per column).
pub const Layout = struct {
    items: [32]Text = undefined,
    len: usize = 0,
    count_buf: [8]u8 = undefined,

    pub fn build(l: *Layout, v: *const View) void {
        l.len = 0;
        l.add(.{ .x = word_x, .y = header_y, .scale = word_scale, .fg = fg, .str = "SNOUTY" });
        l.add(.{ .x = word_x, .y = header_y + 8 * word_scale, .scale = word_scale, .fg = coral, .str = "ARCADE" });

        const first = v.first_visible();
        const last = @min(v.titles.len, @as(usize, first) + visible_rows);
        for (first..last) |i| {
            const row_y: u16 = @intCast(list_y + (i - first) * row_h);
            const t = v.titles[i];
            const selected = i == v.cursor;
            const color = if (!v.is_playable(i)) dim else if (selected) bg else fg;
            if (t.len <= max_title_2x) {
                l.add(.{ .x = margin_x + 8, .y = row_y + (box_h - 16) / 2, .scale = 2, .fg = color, .str = t });
            } else {
                l.add(.{ .x = margin_x + 8, .y = row_y + (box_h - 8) / 2, .fg = color, .str = t[0..@min(t.len, 36)] });
            }
        }

        if (v.cursor < v.titles.len) {
            const blurb = if (!v.is_playable(v.cursor)) "BAD CART IMAGE" else v.blurbs[v.cursor];
            l.add(.{ .x = margin_x, .y = blurb_y, .fg = coral, .str = blurb[0..@min(blurb.len, max_blurb)] });
        }
        const count = std.fmt.bufPrint(&l.count_buf, "{d}/{d}", .{ @as(u32, v.cursor) + 1, v.titles.len }) catch "";
        l.add(.{ .x = @intCast(width - margin_x - count.len * 8), .y = blurb_y, .fg = dim, .str = count });

        l.line(footer_y0, &.{ .{ "UP/DOWN", fg }, .{ " CHOOSE    ", dim }, .{ "C", fg }, .{ " PLAY", dim } });
        l.line(footer_y1, &.{ .{ "HOME", fg }, .{ " MENU    ", dim }, .{ "HOME HOLD", fg }, .{ " BOOTSEL", dim } });
    }

    fn add(l: *Layout, t: Text) void {
        if (l.len == l.items.len) return;
        l.items[l.len] = t;
        l.len += 1;
    }

    /// One centred line of differently coloured segments.
    fn line(l: *Layout, y: u16, segs: []const struct { []const u8, u16 }) void {
        var w: usize = 0;
        for (segs) |s| w += s[0].len * 8;
        var x: u16 = @intCast((width - w) / 2);
        for (segs) |s| {
            l.add(.{ .x = x, .y = y, .fg = s[1], .str = s[0] });
            x += @intCast(s[0].len * 8);
        }
    }
};

fn iris_column(x: u16, out: *[height]u16) void {
    if (x < header_x or x >= header_x + iris_px) return;
    const ix = (x - header_x) / iris_scale;
    for (0..iris.size) |iy| {
        if (!iris.pixel(ix, iy)) continue;
        const y0 = header_y + iy * iris_scale;
        @memset(out[y0 .. y0 + iris_scale], coral);
    }
}

/// Fills out[0..240] with landscape column x (top to bottom).
pub fn render_column(x: u16, v: *const View, l: *const Layout, out: *[height]u16) void {
    @memset(out, bg);
    iris_column(x, out);

    const in_margins = x >= margin_x and x < width - margin_x;
    if (in_margins) {
        @memset(out[rule_y .. rule_y + rule_h], coral);
        out[thin_rule_y] = rule_dim;

        // Row boxes, 1 px corners cut.
        const edge = x == margin_x or x == width - margin_x - 1;
        const first = v.first_visible();
        const last = @min(v.titles.len, @as(usize, first) + visible_rows);
        for (first..last) |i| {
            const y0 = list_y + (i - first) * row_h;
            const color = if (i == v.cursor and v.is_playable(i)) coral else if (i == v.cursor) rule_dim else row_bg;
            if (edge) {
                @memset(out[y0 + 1 .. y0 + box_h - 1], color);
            } else {
                @memset(out[y0 .. y0 + box_h], color);
            }
        }
    }

    for (l.items[0..l.len]) |t| pattern.text_column(t, x, null, out);
}

/// Renders the whole menu into `fb` (row-major, fb[y * width + x]), for the
/// host preview and the tests.
pub fn render(v: *const View, fb: *[width * height]u16) void {
    var l: Layout = .{};
    l.build(v);
    var col: [height]u16 = undefined;
    for (0..width) |x| {
        render_column(@intCast(x), v, &l, &col);
        for (col, 0..) |p, y| fb[y * width + x] = p;
    }
}

// ========================================
// Tests
// ========================================

const testing = std.testing;

const test_titles = [_][]const u8{ "SNOUTY RUN", "DEMOSNOUT", "SNOUTY BUGS", "SNOUTENSTEIN", "SNOUTY MAZE", "SNOUTY REFLECTIONS", "ONE MORE" };
const test_blurbs = [_][]const u8{ "C JUMP", "A SKIP  B HOLD  C PARTS", "", "", "", "", "" };

fn view(cursor: u8) View {
    return .{ .titles = &test_titles, .blurbs = &test_blurbs, .cursor = cursor };
}

fn rendered(v: *const View) *[width * height]u16 {
    const S = struct {
        var fb: [width * height]u16 = undefined;
    };
    render(v, &S.fb);
    return &S.fb;
}

fn row_box_y(row: usize) usize {
    return list_y + row * row_h;
}

test "the cursor row is coral, the others are not" {
    const v = view(1);
    const fb = rendered(&v);
    // A pixel inside each box, left of any text.
    const x = margin_x + 3;
    try testing.expectEqual(row_bg, fb[(row_box_y(0) + 10) * width + x]);
    try testing.expectEqual(coral, fb[(row_box_y(1) + 10) * width + x]);
    try testing.expectEqual(row_bg, fb[(row_box_y(2) + 10) * width + x]);
    // The coral rule and the background.
    try testing.expectEqual(coral, fb[rule_y * width + 100]);
    try testing.expectEqual(bg, fb[2 * width + 2]);
}

test "the list scrolls to keep the cursor visible" {
    var v = view(0);
    try testing.expectEqual(@as(u8, 0), v.first_visible());
    v.cursor = 4;
    try testing.expectEqual(@as(u8, 0), v.first_visible());
    v.cursor = 6;
    try testing.expectEqual(@as(u8, 2), v.first_visible());
    const fb = rendered(&v);
    // The cursor is drawn in the last visible row.
    try testing.expectEqual(coral, fb[(row_box_y(visible_rows - 1) + 10) * width + margin_x + 3]);
}

test "titles fit their boxes and the long one drops to 1x" {
    try testing.expectEqual(@as(usize, 18), max_title_2x);
    var l: Layout = .{};
    const v = view(5);
    l.build(&v);
    var found_long = false;
    for (l.items[0..l.len]) |t| {
        const right = t.x + t.str.len * 8 * t.scale;
        try testing.expect(right <= width - margin_x);
        if (std.mem.eql(u8, t.str, "SNOUTY REFLECTIONS")) {
            found_long = true;
            try testing.expectEqual(@as(u8, 2), t.scale);
        }
    }
    try testing.expect(found_long);
    // Every text item stays on screen vertically too.
    for (l.items[0..l.len]) |t| try testing.expect(t.y + 8 * t.scale <= height);
}

test "a bad cart is dimmed and says so" {
    var v = view(0);
    v.playable = 0b10;
    var l: Layout = .{};
    l.build(&v);
    var said = false;
    for (l.items[0..l.len]) |t| {
        if (std.mem.eql(u8, t.str, "BAD CART IMAGE")) said = true;
        if (std.mem.eql(u8, t.str, "SNOUTY RUN")) try testing.expectEqual(dim, t.fg);
    }
    try testing.expect(said);
}

test "the Iris mark is drawn" {
    const v = view(0);
    const fb = rendered(&v);
    var ink: usize = 0;
    for (header_y..header_y + iris_px) |y| {
        for (header_x..header_x + iris_px) |x| {
            if (fb[y * width + x] == coral) ink += 1;
        }
    }
    try testing.expect(ink > 300);
}
