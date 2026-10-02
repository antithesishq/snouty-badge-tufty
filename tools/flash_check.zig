//! Flash budget check for one cart-host firmware (run by build.zig).
//!
//!   flash_check <name> <firmware.uf2> <limit> [<cart>[@<addr>] <cart.bin>]...
//!
//! Fails (exit 1, message on stderr) when any UF2 block is not RP2350_ARM_S
//! main flash inside 0x10000000..limit, or when a cart image is not found
//! byte-identical in the UF2 payload (with `@<addr>`: not at exactly that
//! address). On success prints the report (stdout, installed as
//! zig-out/firmware/<name>.flash.txt): the flash range, the budget used and
//! each image's flash address.
//!
//! A limit above 0x101C0000 is an XIP cart build (0x10200000): its UF2 also
//! fills the SYCL drive region and the XIP cart window, and the report says so.
const std = @import("std");
const uf2_check = @import("uf2_check");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

const xip_reserved_end: u32 = 0x1020_0000;
/// The SYCL cart window (build.zig xip_window).
const xip_window: u32 = 0x101C_0000;

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

    const xip_build = limit > xip_window;
    const s = switch (uf2_check.check(uf2, limit)) {
        .ok => |s| s,
        .bad => |b| switch (b.problem) {
            .past_limit => if (xip_build) die(
                \\{s}.uf2 reaches 0x{X:0>8} (block {d} at 0x{X:0>8}), past 0x{X:0>8}, where the badge's
                \\  ROMFS and FAT drive start. Nothing of an XIP build may go there.
            , .{ name, b.end, b.block, b.addr, limit }) else die(
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
    // An XIP build's regions sit at fixed addresses with gaps between them,
    // so a "budget used" figure would mean nothing; its regions follow.
    if (!xip_build) try w.print("  budget  0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.0} KB): {d:.1}% used, {d} bytes ({d:.1} KB) free\n", .{
        uf2_check.flash_base, limit, budget, kb(budget), 100.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)), budget - used, kb(budget - used),
    });
    if (xip_build) {
        // Outside the cart window the arcade budget still holds: the OS, the
        // RAM carts and a ROM drive end below 0x101C0000.
        var low_end: u32 = uf2_check.flash_base;
        var off: usize = 0;
        while (off + uf2_check.block_size <= uf2.len) : (off += uf2_check.block_size) {
            const blk = uf2_check.parse_block(uf2[off..][0..uf2_check.block_size]).?;
            if (blk.addr < xip_window) low_end = @max(low_end, blk.addr + blk.size);
        }
        if (low_end > xip_window) die(
            \\{s}.uf2 reaches 0x{X:0>8} outside the XIP cart window, past the flash budget end 0x{X:0>8}.
            \\  The OS and the RAM carts must end below the cart window. See docs/ARCADE.md, "Flash budget".
        , .{ name, low_end, xip_window });
        const budget_low = xip_window - uf2_check.flash_base;
        const used_low = low_end - uf2_check.flash_base;
        try w.print("  budget  0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.0} KB): {d:.1}% used, {d} bytes ({d:.1} KB) free (outside the cart window)\n", .{
            uf2_check.flash_base, xip_window, budget_low, kb(budget_low), 100.0 * @as(f64, @floatFromInt(used_low)) / @as(f64, @floatFromInt(budget_low)), budget_low - used_low, kb(budget_low - used_low),
        });
        try w.print("  the XIP cart window 0x{X:0>8}..0x{X:0>8} holds the XIP cart\n", .{ xip_window, limit });
        try w.print("  0x{X:0>8} and everything above (the badge's ROMFS and FAT drive): untouched\n", .{limit});
    } else {
        try w.print("  0x{X:0>8}..0x{X:0>8} (reserved for an XIP cart) and everything above: untouched\n", .{ limit, xip_reserved_end });
    }

    var carts_total: u32 = 0;
    var first = true;
    while (args.next()) |arg| {
        // `cart@0xADDR`: the image must sit at exactly that address.
        const at_sign = std.mem.indexOfScalar(u8, arg, '@');
        const cart = if (at_sign) |i| arg[0..i] else arg;
        const want: ?u32 = if (at_sign) |i| std.fmt.parseInt(u32, arg[i + 1 ..], 0) catch die("bad address in {s}", .{arg}) else null;
        const bin_path = args.next() orelse die("cart {s}: missing image path", .{cart});
        const blob = cwd.readFileAlloc(io, bin_path, gpa, .limited(16 << 20)) catch |e| die("cannot read {s}: {s}", .{ bin_path, @errorName(e) });
        const len: u32 = @intCast(blob.len);
        if (first) try w.print("  {s} (byte-identical in the UF2 payload):\n", .{if (xip_build) "images (@: required at that address)" else "cart images"});
        first = false;
        if (want) |addr| {
            const off = addr -% uf2_check.flash_base;
            if (addr < uf2_check.flash_base or off + len > image.len or !std.mem.eql(u8, image[off..][0..len], blob))
                die("{s}.uf2: the {s} image ({d} bytes) is not at 0x{X:0>8} byte for byte", .{ name, cart, len, addr });
            try w.print("    {s:<20} 0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.1} KB), at its required address\n", .{ cart, addr, addr + len, len, kb(len) });
        } else {
            const at = uf2_check.locate(image, uf2_check.flash_base, blob) orelse
                die("{s}.uf2: the {s} image ({d} bytes) is not in the UF2 payload byte for byte", .{ name, cart, blob.len });
            try w.print("    {s:<20} 0x{X:0>8}..0x{X:0>8}  {d} bytes ({d:.1} KB){s}\n", .{ cart, at.addr, at.addr + len, len, kb(len), if (at.unique) "" else "  (also found elsewhere)" });
        }
        carts_total += len;
    }
    if (!first and !xip_build) try w.print("  carts {d} bytes ({d:.1} KB), OS + tables {d} bytes ({d:.1} KB)\n", .{ carts_total, kb(carts_total), used - carts_total, kb(used - carts_total) });
    try w.flush();
}
