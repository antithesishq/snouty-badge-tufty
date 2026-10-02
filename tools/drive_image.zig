//! Writes the FAT12 drive image an XIP cart's UF2 carries (run by build.zig).
//!
//!   drive_image <out.img> <rom> <rom basename>
//!
//! The volume is the SYCL OS's 1280 KB romfs (src/fat12_image.zig) with the
//! ROM as its only file, cut after the ROM. `rom basename` is the name the
//! -Dgenesis_rom option ends in; the file on the drive gets its 8.3 form.
//! Prints a short report (installed as firmware/cart/<cart>-drive.txt).
const std = @import("std");
const fat12 = @import("fat12_image");

var io_mem: std.Io.Threaded = .init_single_threaded;
const io = io_mem.io();

/// Where build.zig places the image (lib/romfs.zig base_addr).
const romfs_base: u32 = 0x10080000;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("\nerror: drive image: " ++ fmt ++ "\n\n", args);
    std.process.exit(1);
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;
    var args = try init.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse die("usage: drive_image <out.img> <rom> <rom basename>", .{});
    const rom_path = args.next() orelse die("missing ROM path", .{});
    const basename = args.next() orelse die("missing ROM basename", .{});

    const cwd = std.Io.Dir.cwd();
    const rom = cwd.readFileAlloc(io, rom_path, gpa, .limited(8 << 20)) catch |e|
        die("cannot read the ROM {s}: {s} (-Dgenesis_rom takes an absolute path or one relative to the snouty-tufty repository)", .{ rom_path, @errorName(e) });

    const name = fat12.short_name(basename);
    const img = try gpa.alloc(u8, fat12.image_len(rom.len));
    fat12.write(img, rom, name) catch |e| switch (e) {
        error.RomTooLarge => die("{s} is {d} bytes; the 1280 KB drive holds at most {d}", .{ rom_path, rom.len, fat12.max_rom_bytes() }),
        error.RomEmpty => die("{s} is empty", .{rom_path}),
        error.BadOutputSize => unreachable,
    };
    cwd.writeFile(io, .{ .sub_path = out_path, .data = img }) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });

    var buf: [12]u8 = undefined;
    const l = fat12.layout();
    var out_buf: [1024]u8 = undefined;
    var ow = std.Io.File.stdout().writer(io, &out_buf);
    const w = &ow.interface;
    try w.print("drive image: FAT12, {d} sectors ({d} KB volume, the SYCL romfs geometry), FAT {d} sectors x2, data from sector {d}\n", .{ fat12.total_sectors, fat12.volume_bytes / 1024, l.fat_sectors, l.data_start });
    try w.print("  {s} (from {s}): {d} bytes, clusters 2..{d}, contiguous\n", .{ fat12.display_name(&name, &buf), basename, rom.len, 1 + fat12.clusters_for(rom.len) });
    try w.print("  image {d} bytes, flash 0x{X:0>8}..0x{X:0>8}; ROM at 0x{X:0>8}\n", .{ img.len, romfs_base, romfs_base + img.len, romfs_base + fat12.rom_offset() });
    try w.flush();
}
