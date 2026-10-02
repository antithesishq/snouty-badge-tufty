//! Flash budget check for one cart-host firmware (run by build.zig).
//!
//!   flash_check <name> <firmware.uf2> <limit> [<cart> <cart.bin>]...
//!
//! Fails (exit 1, message on stderr) when any UF2 block is not RP2350_ARM_S
//! main flash inside 0x10000000..limit, or when a cart image is not found
//! byte-identical in the UF2 payload. On success prints the report (stdout,
//! installed as zig-out/firmware/<name>.flash.txt): the flash range, the
//! budget used and each cart image's flash address.
const std = @import("std");
const uf2_check = @import("uf2_check");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

const xip_reserved_end: u32 = 0x1020_0000;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\nerror: flash budget: " ++ fmt ++ "\n\n", args);
    std.process.exit(1);
}

fn kb(bytes: u32) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024.0;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse die("usage: flash_check <name> <uf2> <limit> [<cart> <bin>]...", .{});
    const uf2_path = args.next() orelse die("missing UF2 path", .{});
    const limit_s = args.next() orelse die("missing limit", .{});
    const limit = std.fmt.parseInt(u32, limit_s, 0) catch die("bad limit {s}", .{limit_s});

    const cwd = std.Io.Dir.cwd();
    const uf2 = cwd.readFileAlloc(io, uf2_path, gpa, .limited(64 << 20)) catch |e| die("cannot read {s}: {s}", .{ uf2_path, @errorName(e) });

    const s = switch (uf2_check.check(uf2, limit)) {
        .ok => |s| s,
        .bad => |b| switch (b.problem) {
            .past_limit => die(
                \\{s}.uf2 reaches 0x{X:0>8} (block {d} at 0x{X:0>8}), past the flash budget end 0x{X:0>8}.
                \\  0x{X:0>8}..0x{X:0>8} is reserved for a future XIP cart, and the badge's ROMFS
                \\  and FAT drive start at 0x{X:0>8}. The carts table in build.zig embeds more than
                \\  fits: drop a cart from the arcade (or shrink one). See docs/ARCADE.md, "Flash budget".
            , .{ name, b.end, b.block, b.addr, limit, limit, xip_reserved_end, xip_reserved_end }),
            else => die("{s}.uf2 block {d} (0x{X:0>8}): {s}", .{ name, b.block, b.addr, b.problem.text() }),
        },
    };

    const image = try gpa.alloc(u8, s.hi - uf2_check.flash_base);
    @memset(image, 0xFF);
    uf2_check.flatten(uf2, uf2_check.flash_base, image);

    var out_buf: [4096]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;

    const used = s.hi - uf2_check.flash_base;
    const budget = limit - uf2_check.flash_base;
    try w.print("{s}.uf2\n", .{name});
    try w.print("  {d} blocks, family 0xe48bff59 (RP2350_ARM_S), all main flash\n", .{s.blocks});
    try w.print("  flash   0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.1} KB)\n", .{ s.lo, s.hi, used, kb(used) });
    try w.print("  budget  0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.0} KB): {d:.1}% used, {d} bytes ({d:.1} KB) free\n", .{
        uf2_check.flash_base, limit, budget, kb(budget), 100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)), budget - used, kb(budget - used),
    });
    try w.print("  0x{X:0>8}..0x{X:0>8} (reserved for an XIP cart) and everything above: untouched\n", .{ limit, xip_reserved_end });

    var carts_total: u32 = 0;
    var first = true;
    while (args.next()) |cart| {
        const bin_path = args.next() orelse die("cart {s}: missing image path", .{cart});
        const blob = cwd.readFileAlloc(io, bin_path, gpa, .limited(1 << 20)) catch |e| die("cannot read {s}: {s}", .{ bin_path, @errorName(e) });
        const at = uf2_check.locate(image, uf2_check.flash_base, blob) orelse
            die("{s}.uf2: the {s} image ({d} bytes) is not in the UF2 payload byte for byte", .{ name, cart, blob.len });
        if (first) try w.print("  cart images (byte-identical in the UF2 payload):\n", .{});
        first = false;
        const len: u32 = @intCast(blob.len);
        try w.print("    {s:<20} 0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.1} KB){s}\n", .{ cart, at.addr, at.addr + len, len, kb(len), if (at.unique) "" else "  (also found elsewhere)" });
        carts_total += len;
    }
    if (!first) try w.print("  carts {d} bytes ({d:.1} KB), OS + tables {d} bytes ({d:.1} KB)\n", .{ carts_total, kb(carts_total), used - carts_total, kb(used - carts_total) });
    try w.flush();
}
