//! Host preview of the arcade menu: runs the firmware's own menu drawing
//! code (src/menu.zig) over the build's carts table and writes a PNG.
//!
//!   zig build menu-png        -> docs/arcade-menu.png (2x, 640x480)
//!   menu_png <dir> [cursor]  -> <dir>/arcade-menu.png
const std = @import("std");
const menu = @import("menu");
const meta = @import("cart_meta");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

const scale = 2;
const out_w = menu.width * scale;
const out_h = menu.height * scale;

var fb: [menu.width * menu.height]u16 = undefined;

fn chunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try list.appendSlice(gpa, &len);
    try list.appendSlice(gpa, kind);
    try list.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try list.appendSlice(gpa, &c);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const out_dir = args.next() orelse return error.MissingOutputDir;
    const cursor: u8 = if (args.next()) |c| try std.fmt.parseInt(u8, c, 10) else 0;

    const v: menu.View = .{ .titles = meta.titles, .blurbs = meta.blurbs, .cursor = cursor };
    menu.render(&v, &fb);

    // Raw scanlines: filter byte 0, then RGB8, each panel pixel 2x2.
    var raw: std.ArrayList(u8) = .empty;
    for (0..out_h) |y| {
        try raw.append(gpa, 0);
        for (0..out_w) |x| {
            const p = @byteSwap(fb[(y / scale) * menu.width + x / scale]); // wire is big-endian
            const r: u8 = @intCast((p >> 11) & 0x1F);
            const g: u8 = @intCast((p >> 5) & 0x3F);
            const b: u8 = @intCast(p & 0x1F);
            try raw.appendSlice(gpa, &.{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2) });
        }
    }

    var z: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    const comp = try gpa.create(std.compress.flate.Compress);
    comp.* = try .init(&z.writer, window, .zlib, .best);
    try comp.writer.writeAll(raw.items);
    try comp.finish();

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], out_w, .big);
    std.mem.writeInt(u32, ihdr[4..8], out_h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // RGB
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(&png, gpa, "IHDR", &ihdr);
    try chunk(&png, gpa, "IDAT", z.written());
    try chunk(&png, gpa, "IEND", "");

    const out_path = try std.fs.path.join(gpa, &.{ out_dir, "arcade-menu.png" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = png.items });
    std.debug.print("menu_png: wrote {s} ({d}x{d}, {d} bytes)\n", .{ out_path, out_w, out_h, png.items.len });
}
