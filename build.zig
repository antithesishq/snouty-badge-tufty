//! Snouty Tufty build.
//!
//!   zig build                     firmware into zig-out/firmware/
//!   zig build -Dcart=snouty-run   pick the cart the Tufty OS embeds
//!   zig build -Dscale=crop        cart scale mode: fit, crop, native (default per
//!                                 cart: fit for snouty-run, crop for demosnout)
//!   zig build test                host unit tests
//!
//! Firmware outputs (ELF + UF2, family RP2350_ARM_S, all below 0x10200000):
//!   snouty-tufty-hello       M0 bring-up test screen, clk_sys 250 MHz
//!   snouty-tufty-hello-150   the same at 150 MHz (fallback for the clock path)
//!   snouty-tufty-<cart>      M1 Tufty OS running one SYCL RAM cart, 250 MHz
//!   snouty-tufty-arcade      M2 every cart in `carts` behind a boot menu
//!                            (docs/ARCADE.md)
//!
//!   zig build menu-png            render the arcade menu to docs/arcade-menu.png
//!
//! Each cart-host UF2 is checked after the build (tools/flash_check.zig):
//! nothing may reach 0x101C0000, since 0x101C0000..0x10200000 is kept for
//! a future XIP cart. The report, with every cart image's flash address,
//! is installed next to the UF2 as `<name>.flash.txt`.
//!
//! The cart is built, unmodified, by the snouty-badge submodule's own
//! build.zig (a path dependency), exactly as for the SYCL badge; we take its
//! ELF, objcopy the loadable bytes and embed them.
//!
//! Keep this file free of file-existence or environment branching: this Zig
//! caches the configure-phase graph by build files + options only.
const std = @import("std");
const Build = std.Build;

const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

/// Carts the Tufty OS knows. `name` is the -Dcart name (the directory under
/// snouty-badge/carts/), `binary` the firmware name its build installs,
/// `scale` the cart's default scale mode (-Dscale overrides it in the
/// single-cart build). Optional `title`: the arcade menu line (default: the
/// name in capitals, dashes as spaces). The controls map comes from
/// controls_map.for_cart(name). The order here is the arcade menu order;
/// every row is in snouty-tufty-arcade.uf2 (docs/ARCADE.md).
const Cart = struct { name: []const u8, binary: []const u8, scale: Scale = .fit, title: ?[]const u8 = null };
const carts = [_]Cart{
    .{ .name = "snouty-run", .binary = "snouty" },
    .{ .name = "demosnout", .binary = "demosnout", .scale = .crop },
};

const Scale = enum { fit, crop, native };

/// Arcade menu: a short controls line shown under the highlighted cart
/// (at most 32 characters). A cart without one shows none.
const blurbs = [_][2][]const u8{
    .{ "snouty-run", "C JUMP" },
    .{ "demosnout", "A SKIP  B HOLD  C PARTS" },
};

/// Arcade flash budget: every firmware image must end below this address.
/// 0x101C0000..0x10200000 (256 KB) is reserved for a future XIP cart. The
/// linker's 2 MB flash region still stops anything at 0x10200000 or above.
const flash_limit: u32 = 0x101C0000;

pub fn build(b: *Build) void {
    const cart_name = b.option([]const u8, "cart", "Cart for the Tufty OS image (default snouty-run)") orelse "snouty-run";
    const scale_option = b.option(Scale, "scale", "Cart scale mode: fit (128->240 rows), crop (2x, drop 4 rows top and bottom), native (1:1 centred). Default: per cart (fit unless the carts table says otherwise)");

    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const tufty_target = tufty_microzig_target(mb, b);

    // The SYCL OS 8x8 font, shared through the snouty-badge submodule.
    const font_mod = b.createModule(.{
        .root_source_file = b.path("snouty-badge/sycl-badge/src/font.zig"),
    });

    add_hello(b, mb, tufty_target, font_mod, "snouty-tufty-hello", 250);
    add_hello(b, mb, tufty_target, font_mod, "snouty-tufty-hello-150", 150);

    const cart = for (carts) |c| {
        if (std.mem.eql(u8, c.name, cart_name)) break c;
    } else std.debug.panic("-Dcart: unknown cart '{s}' (known: snouty-run, demosnout)", .{cart_name});
    add_cart_host(b, mb, tufty_target, cart, scale_option orelse cart.scale);

    // M2: every cart of the table behind the boot menu, each at its table scale.
    add_arcade(b, mb, tufty_target);

    const iris_mod = b.createModule(.{
        .root_source_file = b.path("snouty-badge/lib/iris_mark.zig"),
    });

    // Host preview of the arcade menu: zig build menu-png.
    const menu_png = b.addExecutable(.{
        .name = "menu_png",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/menu_png.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "menu", .module = b.createModule(.{
                    .root_source_file = b.path("src/menu.zig"),
                    .imports = &.{
                        .{ .name = "font", .module = font_mod },
                        .{ .name = "iris_mark", .module = iris_mod },
                    },
                }) },
                .{ .name = "cart_meta", .module = cart_meta(b, &carts).createModule() },
            },
        }),
    });
    const run_menu_png = b.addRunArtifact(menu_png);
    run_menu_png.has_side_effects = true;
    run_menu_png.addDirectoryArg(b.path("docs"));
    b.step("menu-png", "Render the arcade menu to docs/arcade-menu.png").dependOn(&run_menu_png.step);

    // Host tests: the pure pixel / pattern / ABI code, no microzig.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "font", .module = font_mod },
                .{ .name = "iris_mark", .module = iris_mod },
            },
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run host unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// One hello firmware at a given clk_sys (MHz).
fn add_hello(
    b: *Build,
    mb: *MicroBuild,
    target: *microzig.Target,
    font_mod: *Build.Module,
    name: []const u8,
    sys_mhz: u32,
) void {
    const options = b.addOptions();
    options.addOption(u32, "sys_mhz", sys_mhz);

    const fw = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/hello.zig"),
        .imports = &.{
            .{ .name = "font", .module = font_mod },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    install(mb, fw);
}

/// One cart's loadable bytes. The monorepo is configured for just this cart
/// (RAM mode, default options); the cart ELF is objcopied from its link
/// address 0x20035100 up to the end of .data (BSS is NOLOAD and is zeroed at
/// launch). `inspect`: also install the ELF and the image under
/// firmware/cart/ (done once per cart, by add_arcade).
fn cart_bin(b: *Build, cart: Cart, inspect: bool) Build.LazyPath {
    const badge = b.dependency("snouty_badge", .{ .cart = cart.name });
    const elf = installed_file(badge.builder, b.fmt("{s}.elf", .{cart.binary}));
    const bin = b.addObjCopy(elf, .{ .basename = b.fmt("{s}.bin", .{cart.binary}), .format = .binary }).getOutput();
    if (inspect) {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(elf, .{ .custom = "firmware/cart" }, b.fmt("{s}.elf", .{cart.binary})).step);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "firmware/cart" }, b.fmt("{s}.bin", .{cart.binary})).step);
    }
    return bin;
}

/// M1: the Tufty OS with one cart embedded, booted straight away.
fn add_cart_host(b: *Build, mb: *MicroBuild, target: *microzig.Target, cart: Cart, scale: Scale) void {
    var single = cart;
    single.scale = scale;
    add_os(b, mb, target, b.fmt("snouty-tufty-{s}", .{cart.name}), &.{single}, &.{cart_bin(b, cart, false)}, false);
}

/// M2: the Tufty OS with every cart of `carts` embedded, behind the menu.
fn add_arcade(b: *Build, mb: *MicroBuild, target: *microzig.Target) void {
    var bins: [carts.len]Build.LazyPath = undefined;
    for (carts, &bins) |c, *bin| bin.* = cart_bin(b, c, true);
    add_os(b, mb, target, "snouty-tufty-arcade", &carts, &bins, true);
}

/// The menu facts of `list` as a module (`cart_meta`): parallel arrays
/// `names`, `titles`, `blurbs` ("" = none) and `scales` (fit/crop/native).
fn cart_meta(b: *Build, list: []const Cart) *Build.Step.Options {
    const names = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const titles = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const blurb_list = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const scales = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    for (list, 0..) |c, i| {
        names[i] = c.name;
        titles[i] = c.title orelse default_title(b, c.name);
        blurb_list[i] = for (blurbs) |bl| {
            if (std.mem.eql(u8, bl[0], c.name)) break bl[1];
        } else "";
        if (blurb_list[i].len > 32) std.debug.panic("blurb for {s} is over 32 characters", .{c.name});
        scales[i] = @tagName(c.scale);
    }
    const meta = b.addOptions();
    meta.addOption([]const []const u8, "names", names);
    meta.addOption([]const []const u8, "titles", titles);
    meta.addOption([]const []const u8, "blurbs", blurb_list);
    meta.addOption([]const []const u8, "scales", scales);
    return meta;
}

/// "snouty-run" -> "SNOUTY RUN".
fn default_title(b: *Build, name: []const u8) []const u8 {
    const t = b.allocator.dupe(u8, name) catch @panic("OOM");
    for (t) |*ch| ch.* = if (ch.* == '-' or ch.* == '_') ' ' else std.ascii.toUpper(ch.*);
    return t;
}

var flash_check_exe: ?*Build.Step.Compile = null;

/// The host tool that checks a firmware UF2 against flash_limit (one,
/// shared by every firmware).
fn flash_check(b: *Build) *Build.Step.Compile {
    if (flash_check_exe) |exe| return exe;
    flash_check_exe = b.addExecutable(.{
        .name = "flash_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/flash_check.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "uf2_check",
                .module = b.createModule(.{ .root_source_file = b.path("src/uf2_check.zig") }),
            }},
        }),
    });
    return flash_check_exe.?;
}

/// The Tufty OS with the carts `list` embedded (`list_bins`: their images,
/// same order). `arcade`: boot into the menu, HOME returns to it. Otherwise
/// boot the first (only) cart, HOME restarts it.
fn add_os(
    b: *Build,
    mb: *MicroBuild,
    target: *microzig.Target,
    name: []const u8,
    list: []const Cart,
    list_bins: []const Build.LazyPath,
    arcade: bool,
) void {
    // `cart_images`: the embedded images by index, so file names stay plain.
    const image_files = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "//! Generated by build.zig: the embedded cart images, in `carts` order.\npub const images = [_][]const u8{\n") catch @panic("OOM");
    for (list_bins, 0..) |bin, i| {
        _ = image_files.addCopyFile(bin, b.fmt("cart{d}.bin", .{i}));
        src.appendSlice(b.allocator, b.fmt("    @embedFile(\"cart{d}.bin\"),\n", .{i})) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const images_src = image_files.add("cart_images.zig", src.items);

    const options = b.addOptions();
    options.addOption(u32, "sys_mhz", 250);
    options.addOption(bool, "arcade", arcade);

    const fw = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/cart_host.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "cart_meta", .module = cart_meta(b, list).createModule() },
            .{ .name = "cart_images", .module = b.createModule(.{ .root_source_file = images_src }) },
            .{ .name = "font", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/sycl-badge/src/font.zig") }) },
            .{ .name = "iris_mark", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/lib/iris_mark.zig") }) },
        },
    });
    install(mb, fw);

    // Flash budget: fails the build with a clear message if the UF2 reaches
    // flash_limit, and writes <name>.flash.txt next to it (range, budget
    // used, the address of every embedded cart image in the UF2).
    const check = b.addRunArtifact(flash_check(b));
    check.addArg(name);
    check.addFileArg(fw.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2350_ARM_S } }));
    check.addArg(b.fmt("0x{X:0>8}", .{flash_limit}));
    for (list, list_bins) |c, bin| {
        check.addArg(c.name);
        check.addFileArg(bin);
    }
    const report = check.captureStdOut(.{});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(report, .{ .custom = "firmware" }, b.fmt("{s}.flash.txt", .{name})).step);
}

/// The source of a file a dependency's build installs under
/// `<prefix>/firmware/<basename>` (microzig's install_firmware). This walks
/// the dependency's configured step graph; it never looks at the disk.
fn installed_file(dep_b: *Build, basename: []const u8) Build.LazyPath {
    for (dep_b.getInstallStep().dependencies.items) |step| {
        const install_file = step.cast(Build.Step.InstallFile) orelse continue;
        const in_firmware = switch (install_file.dir) {
            .custom => |dir| std.mem.eql(u8, dir, "firmware"),
            else => false,
        };
        if (in_firmware and std.mem.eql(u8, install_file.dest_rel_path, basename)) return install_file.source;
    }
    std.debug.panic("snouty-badge build installs no firmware/{s}", .{basename});
}

fn install(mb: *MicroBuild, fw: *MicroBuild.Firmware) void {
    mb.install_firmware(fw, .{ .format = .elf });
    mb.install_firmware(fw, .{ .format = .{ .uf2 = .{ .family_id = .RP2350_ARM_S } } });
}

/// Tufty 2350 target: the Pico 2 (RP2350, Arm) target with our board file
/// and two memory cuts the linker then enforces:
///   - flash 2 MB: 0x10000000..0x10200000 is the stock MicroPython firmware
///     slot; the badge's ROMFS and FAT filesystem start at 0x10200000 and
///     must survive our flash.
///   - main RAM 128 KB: 0x20020000..0x20080000 belongs to the cart (SYCL
///     cart ABI: IPC block, cart image at 0x20035100, cart stack at the top).
///     The OS's data, BSS and stack stay below 0x20020000.
fn tufty_microzig_target(mb: *MicroBuild, b: *Build) *microzig.Target {
    const base_target = mb.ports.rp2xxx.boards.raspberrypi.pico2_arm;

    var chip = base_target.chip;
    chip.memory_regions = &.{
        .{ .tag = .flash, .offset = 0x10000000, .length = 2 * 1024 * 1024, .access = .rx },
        .{ .tag = .ram, .offset = 0x20000000, .length = 128 * 1024, .access = .rwx },
        .{ .tag = .ram, .offset = 0x20080000, .length = 4 * 1024, .access = .rwx },
        .{ .tag = .ram, .offset = 0x20081000, .length = 4 * 1024, .access = .rwx },
    };

    return base_target.derive(.{
        .chip = chip,
        .board = .{
            .name = "Pimoroni Tufty 2350",
            .url = "https://shop.pimoroni.com/products/tufty-2350",
            .root_source_file = b.path("src/board.zig"),
        },
    });
}
