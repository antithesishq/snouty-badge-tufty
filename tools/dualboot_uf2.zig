//! Dual-boot UF2 builder and checker (run by build.zig, docs/DUALBOOT.md).
//!
//!   dualboot_uf2 <name> <firmware.elf> <stub.bin> <out.uf2> [<cart> <cart.bin>]...
//!
//! <firmware.elf> is the dual-boot arcade, linked at the 0x10000000 runtime
//! address the bootrom maps its window to. This writes <out.uf2> with the
//! launcher sector (header + stub.bin) at 0x1014F000 and the arcade image at
//! 0x10150000, then re-reads the UF2 and fails the build (exit 1, message on
//! stderr) unless:
//!   - every block is RP2350_ARM_S main flash inside 0x1014F000..0x10200000,
//!     so flashing it never writes MicroPython (..0x1014E220), its ROMFS
//!     (0x10200000..) or its FAT drive
//!   - the image fits the 704 KB window, has its vector table and IMAGE_DEF
//!     where chain_image() looks, and reads back byte for byte
//!   - every cart image is in the payload byte for byte
//! On success the report goes to stdout (installed as <name>.flash.txt).
const std = @import("std");
const dualboot = @import("dualboot");
const layout = dualboot.layout;
const pack = dualboot.pack;
const uf2_check = dualboot.uf2_check;

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\nerror: dual boot: " ++ fmt ++ "\n\n", args);
    std.process.exit(1);
}

fn kb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024.0;
}

const CartArg = struct { name: []const u8, blob: []const u8 };

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const name = args.next() orelse die("usage: dualboot_uf2 <name> <elf> <stub.bin> <out.uf2> [<cart> <bin>]...", .{});
    const elf_path = args.next() orelse die("missing ELF path", .{});
    const stub_path = args.next() orelse die("missing stub path", .{});
    const out_path = args.next() orelse die("missing output path", .{});

    const cwd = std.Io.Dir.cwd();
    const read = struct {
        fn f(d: std.Io.Dir, a: std.mem.Allocator, path: []const u8) []u8 {
            return d.readFileAlloc(io, path, a, .limited(64 << 20)) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
        }
    }.f;

    var carts: std.ArrayList(CartArg) = .empty;
    while (args.next()) |cart| {
        const bin = args.next() orelse die("cart {s}: missing image path", .{cart});
        try carts.append(gpa, .{ .name = cart, .blob = read(cwd, gpa, bin) });
    }

    const elf = read(cwd, gpa, elf_path);
    const image = pack.image_from_elf(gpa, elf) catch |e|
        die("{s}: {s}: {s} (every loadable byte must be in flash from 0x{X:0>8})", .{ name, elf_path, @errorName(e), layout.runtime_base });
    if (image.len > layout.window_size) too_large(name, carts.items, image.len);
    const info = pack.check_image(image) catch |e|
        die("{s}: the arcade image is not what chain_image() can enter: {s}", .{ name, @errorName(e) });

    const stub = read(cwd, gpa, stub_path);
    const launcher = pack.launcher_bytes(gpa, stub, image) catch |e|
        die("{s}: launch stub {s}: {s}", .{ name, stub_path, @errorName(e) });

    const uf2 = try pack.pack(gpa, launcher, image);
    cwd.writeFile(io, .{ .sub_path = out_path, .data = uf2 }) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });

    // Check the UF2 as written, from scratch.
    const s = switch (uf2_check.check_range(uf2, layout.gap_start, layout.gap_end)) {
        .ok => |s| s,
        .bad => |b| die("{s}.uf2 block {d} (0x{X:0>8}..0x{X:0>8}): {s}; only 0x{X:0>8}..0x{X:0>8} may be written", .{
            name, b.block, b.addr, b.end, b.problem.text(), layout.gap_start, layout.gap_end,
        }),
    };
    const flash = try gpa.alloc(u8, layout.gap_end - layout.gap_start);
    @memset(flash, 0xFF);
    uf2_check.flatten(uf2, layout.gap_start, flash);
    const hdr = layout.Header.decode(flash[0..layout.stub_offset]) orelse die("{s}.uf2: the launcher header does not read back", .{name});
    const window = flash[layout.window_base - layout.gap_start ..];
    if (hdr.stub_len != stub.len or hdr.stub_crc != layout.crc32(flash[layout.stub_offset..][0..stub.len]) or
        hdr.image_len != image.len or hdr.image_crc != layout.crc32(window[0..image.len]) or
        !std.mem.eql(u8, window[0..image.len], image))
        die("{s}.uf2: the launcher sector or the image does not read back", .{name});

    var out_buf: [8192]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;

    const free = layout.window_size - image.len;
    try w.print("{s}.uf2  (dual boot beside the badge's Supabase MicroPython, docs/DUALBOOT.md)\n", .{name});
    try w.print("  {d} blocks, family 0xe48bff59 (RP2350_ARM_S), all main flash\n", .{s.blocks});
    try w.print("  writes  0x{X:0>8}..0x{X:0>8} only, inside the gap 0x{X:0>8}..0x{X:0>8}\n", .{ s.lo, s.hi, layout.gap_start, layout.gap_end });
    try w.print("  untouched: 0x10000000..0x{X:0>8} (MicroPython bw-1.29.0 ends 0x{X:0>8}) and 0x{X:0>8}.. (ROMFS, FAT drive)\n", .{ layout.gap_start, layout.micropython_end, layout.gap_end });
    try w.print("  launcher 0x{X:0>8}: header v{d} + launch stub {d} bytes (CRC-32 0x{X:0>8})\n", .{ layout.launcher_sector, layout.header_version, stub.len, hdr.stub_crc });
    try w.print("  window   0x{X:0>8}..0x{X:0>8} ({d:.0} KB), mapped to 0x{X:0>8} by the bootrom (QMI ATRANS0)\n", .{ layout.window_base, layout.gap_end, kb(layout.window_size), layout.runtime_base });
    try w.print("  image    0x{X:0>8}..0x{X:0>8} = runtime 0x{X:0>8}..0x{X:0>8}, {d} bytes ({d:.1} KB): {d:.1}% of the window, {d} bytes ({d:.1} KB) free\n", .{
        layout.window_base, layout.window_base + image.len, layout.runtime_base,                                                                      layout.runtime_base + image.len,
        image.len,          kb(image.len),                  100.0 * @as(f64, @floatFromInt(image.len)) / @as(f64, @floatFromInt(layout.window_size)), free,
        kb(free),
    });
    try w.print("  entry    vector table at runtime 0x{X:0>8}: SP 0x{X:0>8}, reset 0x{X:0>8}; IMAGE_DEF (EXE, Secure, Arm, RP2350) at +0x{X}\n", .{ layout.runtime_base, info.initial_sp, info.reset, info.image_def_at });

    var carts_total: usize = 0;
    try w.print("  cart images (byte-identical in the UF2 payload), in menu order:\n", .{});
    for (carts.items) |c| {
        const at = uf2_check.locate(window[0..image.len], layout.window_base, c.blob) orelse
            die("{s}.uf2: the {s} image ({d} bytes) is not in the UF2 payload byte for byte", .{ name, c.name, c.blob.len });
        const rt = at.addr - layout.window_base + layout.runtime_base;
        try w.print("    {s:<20} 0x{X:0>8}..0x{X:0>8} (runtime 0x{X:0>8})  {d} bytes ({d:.1} KB){s}\n", .{
            c.name, at.addr, at.addr + c.blob.len, rt, c.blob.len, kb(c.blob.len), if (at.unique) "" else "  (also found elsewhere)",
        });
        carts_total += c.blob.len;
    }
    try w.print("  carts {d} bytes ({d:.1} KB), OS + tables {d} bytes ({d:.1} KB)\n", .{ carts_total, kb(carts_total), image.len - carts_total, kb(image.len - carts_total) });
    try w.flush();
}

/// The image does not fit the window: say by how much and which carts to drop.
fn too_large(name: []const u8, carts: []const CartArg, n: usize) noreturn {
    var total: usize = 0;
    for (carts) |c| total += c.blob.len;
    var biggest: []const u8 = "?";
    var biggest_len: usize = 0;
    for (carts) |c| if (c.blob.len > biggest_len) {
        biggest = c.name;
        biggest_len = c.blob.len;
    };
    die(
        \\{s}.uf2: the arcade image is {d} bytes ({d:.1} KB), over the {d:.0} KB window
        \\  0x{X:0>8}..0x{X:0>8} by {d} bytes. The carts take {d} bytes; the biggest is {s}
        \\  ({d} bytes). Choose fewer with -Ddualboot_carts=a,b,c (see docs/DUALBOOT.md).
    , .{ name, n, kb(n), kb(layout.window_size), layout.window_base, layout.gap_end, n - layout.window_size, total, biggest, biggest_len });
}
