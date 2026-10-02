//! Adds flash regions to a firmware UF2 (run by build.zig for XIP carts).
//!
//!   uf2_pack <out.uf2> <base.uf2> [<addr> <file>]...
//!
//! See src/uf2_pack.zig. Fails (exit 1, message on stderr) on an overlap, an
//! unaligned address or a base that is not an RP2350_ARM_S UF2.
const std = @import("std");
const uf2_pack = @import("uf2_pack");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\nerror: uf2_pack: " ++ fmt ++ "\n\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse die("usage: uf2_pack <out.uf2> <base.uf2> [<addr> <file>]...", .{});
    const base_path = args.next() orelse die("missing base UF2", .{});
    const cwd = std.Io.Dir.cwd();
    const base = cwd.readFileAlloc(io, base_path, gpa, .limited(64 << 20)) catch |e| die("cannot read {s}: {s}", .{ base_path, @errorName(e) });

    var regions: std.ArrayList(uf2_pack.Region) = .empty;
    while (args.next()) |addr_s| {
        const addr = std.fmt.parseInt(u32, addr_s, 0) catch die("bad address {s}", .{addr_s});
        const path = args.next() orelse die("address {s}: missing file", .{addr_s});
        const bytes = cwd.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
        try regions.append(gpa, .{ .addr = addr, .bytes = bytes });
    }

    const out = uf2_pack.pack(gpa, base, regions.items) catch |e| die("{s}: {s}", .{ out_path, @errorName(e) });
    cwd.writeFile(io, .{ .sub_path = out_path, .data = out }) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });
}
