//! Snouty Tufty build.
//!
//!   zig build                     firmware into zig-out/firmware/
//!   zig build -Dcart=snouty-run   pick the cart the Tufty OS embeds
//!   zig build -Dscale=crop        cart scale mode: fit, crop, native (default per
//!                                 cart: fit for snouty-run, crop for demosnout)
//!   zig build test                host unit tests
//!   zig build -Dcart=snouty-genesis -Dgenesis_rom=/abs/path/rom.bin
//!                                 the Genesis emulator (an XIP cart) with that
//!                                 ROM on a FAT12 drive image in the same UF2
//!                                 (default ROM: the cart's open Miniplanets;
//!                                 docs/ports/snouty-genesis.md)
//!
//! Firmware outputs (ELF + UF2, family RP2350_ARM_S, all below 0x10200000):
//!   snouty-tufty-hello       M0 bring-up test screen, clk_sys 250 MHz
//!   snouty-tufty-hello-150   the same at 150 MHz (fallback for the clock path)
//!   snouty-tufty-<cart>      M1 Tufty OS running one SYCL RAM cart, 250 MHz
//!   snouty-tufty-arcade      M2 every arcade cart in `carts` behind a boot
//!                            menu: the RAM carts embedded, and the one XIP
//!                            cart (snouty-zero) at 0x101C0000 (docs/ARCADE.md)
//!   snouty-tufty-snouty-zero the Tufty OS + the snouty-zero XIP cart at
//!                            0x101C0000 (-Dcart=snouty-zero)
//!   snouty-tufty-genesis     the Tufty OS + the genesis XIP cart at
//!                            0x101C0000 + a FAT12 drive holding the ROM at
//!                            0x10080000, in one UF2 (`xip` carts, below)
//!   snouty-tufty-arcade-supabase  the arcade as a dual boot beside the
//!                            badge's own MicroPython: its UF2 only writes the
//!                            free gap 0x1014F000..0x10200000 (docs/DUALBOOT.md;
//!                            -Ddualboot_carts=a,b,c picks its carts;
//!                            `zig build supabase` builds just it)
//!
//!   zig build menu-png            render the arcade menu to docs/arcade-menu.png
//!
//! Each cart-host UF2 is checked after the build (tools/flash_check.zig):
//! nothing but the XIP cart may reach 0x101C0000, since
//! 0x101C0000..0x10200000 is the XIP cart window, and nothing may reach
//! 0x10200000. The report, with every cart image's flash address, is
//! installed next to the UF2 as `<name>.flash.txt`.
//!
//! The cart is built by the snouty-badge submodule's own build.zig (a path
//! dependency) from its `tufty` branch, as for the SYCL badge but with
//! -Dbadge=tufty (Tufty button names on screen; docs/CARTS.md); we take its
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
/// `reflections_variant`: the monorepo's -Dreflections_variant for that cart
/// (null: the option is not passed). `maze_size`: the monorepo's
/// -Dmaze_size for snouty-maze (null: its default, 12).
/// `xip`: an execute-in-place cart (the monorepo's -Dcart-mode=xip), linked
/// to the SYCL cart flash window 0x101C0000..0x10200000. The OS embeds no
/// image for it; the UF2 carries the image at that address (tools/uf2_pack),
/// and the OS validates and launches it from there. One window, so at most
/// one XIP cart per firmware; the arcade may hold one beside its RAM carts.
/// `arcade`: false keeps a row out of the arcade (single-cart build only).
/// `uf2`: the single-cart UF2 is snouty-tufty-<uf2> (default: the name).
/// `rom_drive`: the UF2 also carries a FAT12 drive at 0x10080000 (the SYCL
/// romfs) holding -Dgenesis_rom, which the cart reads in place. It overlaps
/// the arcade's RAM carts, so such a cart is single-cart only.
const Cart = struct {
    name: []const u8,
    binary: []const u8,
    scale: Scale = .fit,
    title: ?[]const u8 = null,
    reflections_variant: ?[]const u8 = null,
    maze_size: ?u8 = null,
    xip: bool = false,
    arcade: bool = true,
    uf2: ?[]const u8 = null,
    rom_drive: bool = false,
};
const carts = [_]Cart{
    .{ .name = "snouty-run", .binary = "snouty" },
    .{ .name = "demosnout", .binary = "demosnout", .scale = .crop },
    .{ .name = "snoutenstein", .binary = "snoutenstein" },
    .{ .name = "snouty-bugs", .binary = "snouty-bugs", .title = "SNOUTY BUGHUNT" },
    // Crop: an exact 2x keeps the dither cells regular and the spheres round.
    // tufty20 = full15's scene at 20 fps, on the snouty-badge `tufty` branch (docs/CARTS.md).
    .{ .name = "snouty-reflections", .binary = "snouty-reflections", .scale = .crop, .reflections_variant = "tufty20" },
    // 16x16 (the cart's maximum): 15.3 ms worst modelled at 150 MHz, ~9.2 ms
    // at 250 MHz (docs/ports/snouty-maze.md).
    .{ .name = "snouty-maze", .binary = "snouty-maze", .maze_size = 16 },
    // Fit: the verb caption is at y 119..127, which crop would cut. The
    // cart's own 30 fps lock and options (docs/ports/snouty-flyover.md).
    .{ .name = "snouty-flyover", .binary = "snouty-flyover" },
    // The arcade's one XIP cart (the monorepo builds it XIP-only since its
    // M5): its image is packed at 0x101C0000, not embedded. Fit: the HUD's
    // lap/clock/rank at y 1..8 and the snapshot bar and minimap down to
    // y 126, which crop would cut (docs/ports/snouty-zero.md).
    .{ .name = "snouty-zero", .binary = "snouty-zero", .xip = true },
    // XIP with its ROM on a FAT12 drive: its own UF2 only,
    // snouty-tufty-genesis.uf2 (docs/ports/snouty-genesis.md). Fit keeps all
    // 128 rows: the cart's menu footer, scrub bar and hint strip sit on its
    // bottom rows, which crop cuts.
    .{ .name = "snouty-genesis", .binary = "snouty-genesis", .xip = true, .arcade = false, .uf2 = "genesis", .rom_drive = true },
};

const Scale = enum { fit, crop, native };

/// Arcade menu: a short controls line shown under the highlighted cart
/// (at most 32 characters). A cart without one shows none.
const blurbs = [_][2][]const u8{
    .{ "snouty-run", "C JUMP" },
    .{ "demosnout", "A SKIP  B HOLD  C PARTS" },
    .{ "snoutenstein", "A/B TURN  UP/DN WALK  C FIRE" },
    .{ "snouty-bugs", "C FIRE  A+B REWIND  UP+DN PAUSE" },
    .{ "snouty-reflections", "A/B ORBIT  UP/DN HIGH  C FREEZE" },
    .{ "snouty-maze", "A/B TURN  UP/DN STEP  C SKIP" },
    .{ "snouty-flyover", "C VERB  A+B BOOST  UP+DN SKIP" },
    .{ "snouty-zero", "C GO  UP BOOST  A+B REWIND" },
};

/// Arcade flash budget: every firmware image must end below this address.
/// 0x101C0000..0x10200000 (256 KB) is the XIP cart window. The
/// linker's 2 MB flash region still stops anything at 0x10200000 or above.
const flash_limit: u32 = 0x101C0000;

/// The SYCL flash layout an XIP cart is linked for (sycl-badge
/// src/os/linker.ld and src/cart/cart_xip.ld at a6ce19f, snouty-badge
/// lib/romfs.zig): the romfs (FAT12 drive) region, then the 256 KB cart
/// window. An XIP build ends at xip_window_end, where the badge's own ROMFS
/// starts.
const romfs_base: u32 = 0x10080000;
const xip_window: u32 = 0x101C0000;
const xip_window_end: u32 = 0x10200000;

/// The default -Dgenesis_rom: Sik's Miniplanets (zlib licence), shipped with
/// the cart (snouty-badge/carts/snouty-genesis/roms/LICENSE-miniplanets).
const default_genesis_rom = "snouty-badge/carts/snouty-genesis/roms/miniplanets.bin";

pub fn build(b: *Build) void {
    const cart_name = b.option([]const u8, "cart", "Cart for the Tufty OS image (default snouty-run)") orelse "snouty-run";
    const scale_option = b.option(Scale, "scale", "Cart scale mode: fit (128->240 rows), crop (2x, drop 4 rows top and bottom), native (1:1 centred). Default: per cart (fit unless the carts table says otherwise)");
    // A path only: absolute, or relative to this repository. No `~`
    // expansion and no existence probe (the configure-cache rule above); a
    // missing file fails the build when the drive image is written.
    const genesis_rom = b.option([]const u8, "genesis_rom", "snouty-genesis: the Genesis ROM for the UF2's FAT12 drive (absolute, or relative to this repository; default " ++ default_genesis_rom ++ ", zlib). Never commit a commercial ROM") orelse default_genesis_rom;

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
    } else std.debug.panic("-Dcart: unknown cart '{s}' (see the carts table in build.zig)", .{cart_name});
    add_cart_host(b, mb, tufty_target, cart, scale_option orelse cart.scale, genesis_rom);

    // M2: every arcade cart of the table behind the boot menu, each at its table scale.
    add_arcade(b, mb, tufty_target, genesis_rom);

    // Dual boot beside the Supabase MicroPython firmware (docs/DUALBOOT.md).
    add_supabase(b, mb, tufty_target);

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
                .{ .name = "cart_meta", .module = cart_meta(b, arcade_carts(b)).createModule() },
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
                // The cart's own FAT12 reader: the drive image tests read
                // their images back through it.
                .{ .name = "romfs", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/lib/romfs.zig") }) },
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
/// (RAM mode, -Dbadge=tufty, otherwise default options); the cart ELF is objcopied from its link
/// address 0x20035100 up to the end of .data (BSS is NOLOAD and is zeroed at
/// launch). `inspect`: also install the ELF and the image under
/// firmware/cart/ (done once per cart, by add_arcade).
fn cart_bin(b: *Build, cart: Cart, inspect: bool) Build.LazyPath {
    // -Dbadge=tufty (every cart): Tufty button names in the carts' on-screen
    // text and a clock-seeded snouty-maze (snouty-badge `tufty` branch,
    // docs/CARTS.md). Carts without such text ignore it. An XIP cart is
    // built with -Dcart-mode=xip, and its ELF is <binary>-xip.elf.
    const mode: []const u8 = if (cart.xip) "xip" else "ram";
    const badge = if (cart.reflections_variant) |v|
        b.dependency("snouty_badge", .{ .cart = cart.name, .badge = "tufty", .@"cart-mode" = mode, .reflections_variant = v })
    else if (cart.maze_size) |n|
        b.dependency("snouty_badge", .{ .cart = cart.name, .badge = "tufty", .@"cart-mode" = mode, .maze_size = n })
    else
        b.dependency("snouty_badge", .{ .cart = cart.name, .badge = "tufty", .@"cart-mode" = mode });
    const stem = if (cart.xip) b.fmt("{s}-xip", .{cart.binary}) else cart.binary;
    const elf = installed_file(badge.builder, b.fmt("{s}.elf", .{stem}));
    // RAM: from 0x20035100 to the end of .data. XIP: from the cart window
    // 0x101C0000 (vector table first) to the end of .data's flash copy.
    const bin = b.addObjCopy(elf, .{ .basename = b.fmt("{s}.bin", .{stem}), .format = .binary }).getOutput();
    if (inspect) {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(elf, .{ .custom = "firmware/cart" }, b.fmt("{s}.elf", .{stem})).step);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(bin, .{ .custom = "firmware/cart" }, b.fmt("{s}.bin", .{stem})).step);
    }
    return bin;
}

/// What a cart puts in the UF2: its image (RAM: embedded in the OS; XIP:
/// packed at xip_window) and, for a `rom_drive` cart, the FAT12 drive (packed
/// at romfs_base) and the ROM file on it.
const CartParts = struct {
    image: Build.LazyPath,
    drive: ?Build.LazyPath = null,
    rom: ?Build.LazyPath = null,
};

fn cart_parts(b: *Build, cart: Cart, inspect: bool, rom_path: []const u8) CartParts {
    const image = cart_bin(b, cart, inspect);
    if (!cart.rom_drive) return .{ .image = image };

    const rom: Build.LazyPath = if (std.fs.path.isAbsolute(rom_path)) .{ .cwd_relative = rom_path } else b.path(rom_path);
    const make_drive = b.addRunArtifact(host_tool(b, "drive_image", &.{.{ .name = "fat12_image", .path = "src/fat12_image.zig" }}));
    const drive = make_drive.addOutputFileArg(b.fmt("{s}-drive.img", .{cart.binary}));
    make_drive.addFileArg(rom);
    // The file name on the drive comes from the option's basename (a string
    // operation, not a file probe): sonic1.bin -> SONIC1.BIN.
    make_drive.addArg(std.fs.path.basename(rom_path));
    const drive_report = make_drive.captureStdOut(.{});
    const dir: Build.InstallDir = .{ .custom = "firmware/cart" };
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(drive, dir, b.fmt("{s}-drive.img", .{cart.binary})).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(drive_report, dir, b.fmt("{s}-drive.txt", .{cart.binary})).step);
    return .{ .image = image, .drive = drive, .rom = rom };
}

/// M1: the Tufty OS with one cart, booted straight away. A RAM cart is
/// embedded; an XIP cart (snouty-genesis) is packed into the UF2 at the cart
/// window, with its drive if it has one, and runs exactly as on the SYCL
/// badge: code from the window, the ROM read in place from the drive.
fn add_cart_host(b: *Build, mb: *MicroBuild, target: *microzig.Target, cart: Cart, scale: Scale, rom_path: []const u8) void {
    var single = cart;
    single.scale = scale;
    // An XIP cart's ELF and image are installed under firmware/cart/ (the
    // arcade does it for its own rows).
    add_os(b, mb, target, b.fmt("snouty-tufty-{s}", .{cart.uf2 orelse cart.name}), &.{single}, &.{cart_parts(b, cart, cart.xip and !cart.arcade, rom_path)}, false);
}

/// The rows of `carts` the arcade holds (`arcade = true`): the RAM carts and
/// at most one XIP cart. A `rom_drive` cart cannot be one: its drive at
/// 0x10080000 would overlap the RAM carts.
fn arcade_carts(b: *Build) []const Cart {
    var list: std.ArrayList(Cart) = .empty;
    var xips: u32 = 0;
    for (carts) |c| {
        if (!c.arcade) continue;
        if (c.rom_drive) std.debug.panic("{s}: a rom_drive cart cannot be in the arcade (set .arcade = false)", .{c.name});
        if (c.xip) xips += 1;
        list.append(b.allocator, c) catch @panic("OOM");
    }
    if (xips > 1) std.debug.panic("the arcade holds at most one XIP cart (one cart window)", .{});
    return list.items;
}

/// M2: the Tufty OS with every arcade cart of `carts`, behind the menu.
fn add_arcade(b: *Build, mb: *MicroBuild, target: *microzig.Target, rom_path: []const u8) void {
    const list = arcade_carts(b);
    const parts = b.allocator.alloc(CartParts, list.len) catch @panic("OOM");
    for (list, parts) |c, *p| p.* = cart_parts(b, c, true, rom_path);
    add_os(b, mb, target, "snouty-tufty-arcade", list, parts, true);
}

/// The menu facts of `list` as a module (`cart_meta`): parallel arrays
/// `names`, `titles`, `blurbs` ("" = none), `scales` (fit/crop/native) and
/// `xips` (true: an XIP cart, run from the flash window).
fn cart_meta(b: *Build, list: []const Cart) *Build.Step.Options {
    const names = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const titles = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const blurb_list = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const scales = b.allocator.alloc([]const u8, list.len) catch @panic("OOM");
    const xips = b.allocator.alloc(bool, list.len) catch @panic("OOM");
    for (list, 0..) |c, i| {
        xips[i] = c.xip;
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
    meta.addOption([]const bool, "xips", xips);
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

/// The Tufty OS with the carts `list` (`parts`: their images and drives,
/// same order). `arcade`: boot into the menu, HOME returns to it. Otherwise
/// boot the first (only) cart, HOME restarts it.
///
/// RAM carts are embedded in the OS. An XIP cart (at most one) is not: its
/// slot gets an empty image, and tools/uf2_pack.zig adds its image at the
/// cart window, plus a `rom_drive` cart's drive at romfs_base, to the OS's
/// UF2 (the OS firmware is then built as `<name>-os`, and the packed UF2 is
/// `<name>.uf2`). The OS learns the packed regions' lengths and CRC32s from
/// the generated `xip_meta` module and checks them at boot.
fn add_os(
    b: *Build,
    mb: *MicroBuild,
    target: *microzig.Target,
    name: []const u8,
    list: []const Cart,
    parts: []const CartParts,
    arcade: bool,
) void {
    // The regions the UF2 packs besides the OS.
    var xip_image: ?Build.LazyPath = null;
    var xip_name: []const u8 = "";
    var drive: ?Build.LazyPath = null;
    var rom: ?Build.LazyPath = null;
    for (list, parts) |c, p| {
        if (c.xip) {
            if (xip_image != null) std.debug.panic("{s}: at most one XIP cart per firmware (one cart window)", .{name});
            xip_image = p.image;
            xip_name = c.name;
        }
        if (p.drive) |d| {
            if (!c.xip) std.debug.panic("{s}: rom_drive is for XIP carts", .{c.name});
            drive = d;
            rom = p.rom;
        }
    }
    const packs = xip_image != null;

    // `cart_images`: the embedded images by index, so file names stay plain.
    const image_files = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "//! Generated by build.zig: the embedded cart images, in `carts` order.\npub const images = [_][]const u8{\n") catch @panic("OOM");
    for (list, parts, 0..) |c, p, i| {
        // An XIP cart's image is in the flash window, not in the OS.
        if (c.xip) {
            _ = image_files.add(b.fmt("cart{d}.bin", .{i}), "");
        } else {
            _ = image_files.addCopyFile(p.image, b.fmt("cart{d}.bin", .{i}));
        }
        src.appendSlice(b.allocator, b.fmt("    @embedFile(\"cart{d}.bin\"),\n", .{i})) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const images_src = image_files.add("cart_images.zig", src.items);

    const options = b.addOptions();
    options.addOption(u32, "sys_mhz", 250);
    options.addOption(bool, "arcade", arcade);

    // `xip_meta`: what the UF2 puts in the cart window and the drive region
    // (lengths and CRC32s, tools/xip_meta.zig), or `present = false`.
    const xip_meta_src: Build.LazyPath = if (xip_image) |image| blk: {
        const run = b.addRunArtifact(host_tool(b, "xip_meta", &.{}));
        run.addArg(b.fmt("0x{X:0>8}", .{xip_window}));
        run.addFileArg(image);
        if (drive) |d| {
            run.addArg(b.fmt("0x{X:0>8}", .{romfs_base}));
            run.addFileArg(d);
        }
        break :blk run.captureStdOut(.{ .basename = "xip_meta.zig" });
    } else b.addWriteFiles().add("xip_meta.zig",
        \\//! Generated by build.zig: this firmware has no XIP cart.
        \\pub const present = false;
        \\pub const image_addr: u32 = 0;
        \\pub const image_len: u32 = 0;
        \\pub const image_crc: u32 = 0;
        \\pub const drive_addr: u32 = 0;
        \\pub const drive_len: u32 = 0;
        \\pub const drive_crc: u32 = 0;
        \\
    );

    const fw = mb.add_firmware(.{
        .name = if (packs) b.fmt("{s}-os", .{name}) else name,
        .target = target,
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/cart_host.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "cart_meta", .module = cart_meta(b, list).createModule() },
            .{ .name = "cart_images", .module = b.createModule(.{ .root_source_file = images_src }) },
            .{ .name = "xip_meta", .module = b.createModule(.{ .root_source_file = xip_meta_src }) },
            .{ .name = "font", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/sycl-badge/src/font.zig") }) },
            .{ .name = "iris_mark", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/lib/iris_mark.zig") }) },
        },
    });
    const os_uf2 = fw.get_emitted_bin(.{ .uf2 = .{ .family_id = .RP2350_ARM_S } });

    // The UF2 to flash: the OS's own, or with an XIP cart the OS's plus the
    // cart window (and the drive) (tools/uf2_pack.zig: one block sequence,
    // renumbered, overlaps refused).
    const uf2 = if (xip_image) |image| blk: {
        mb.install_firmware(fw, .{ .format = .elf });
        const pack = b.addRunArtifact(host_tool(b, "uf2_pack", &.{.{ .name = "uf2_pack", .path = "src/uf2_pack.zig" }}));
        const out = pack.addOutputFileArg(b.fmt("{s}.uf2", .{name}));
        pack.addFileArg(os_uf2);
        if (drive) |d| {
            pack.addArg(b.fmt("0x{X:0>8}", .{romfs_base}));
            pack.addFileArg(d);
        }
        pack.addArg(b.fmt("0x{X:0>8}", .{xip_window}));
        pack.addFileArg(image);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(out, .{ .custom = "firmware" }, b.fmt("{s}.uf2", .{name})).step);
        break :blk out;
    } else blk: {
        install(mb, fw);
        break :blk os_uf2;
    };

    // Flash budget: fails the build with a clear message if the UF2 reaches
    // its limit (flash_limit; with an XIP cart 0x10200000, and then
    // everything outside the cart window must still end below flash_limit),
    // and writes <name>.flash.txt next to it (range, budget used, the address
    // of every image in the UF2; the XIP image and the drive are required at
    // their addresses).
    const check = b.addRunArtifact(flash_check(b));
    check.addArg(name);
    check.addFileArg(uf2);
    check.addArg(b.fmt("0x{X:0>8}", .{if (packs) xip_window_end else flash_limit}));
    for (list, parts) |c, p| {
        if (c.xip) continue;
        check.addArg(c.name);
        check.addFileArg(p.image);
    }
    if (drive) |d| {
        check.addArg(b.fmt("drive@0x{X:0>8}", .{romfs_base}));
        check.addFileArg(d);
        check.addArg("rom");
        check.addFileArg(rom.?);
    }
    if (xip_image) |image| {
        check.addArg(b.fmt("{s}@0x{X:0>8}", .{ xip_name, xip_window }));
        check.addFileArg(image);
    }
    const report = check.captureStdOut(.{});
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(report, .{ .custom = "firmware" }, b.fmt("{s}.flash.txt", .{name})).step);
}

const ToolImport = struct { name: []const u8, path: []const u8 };

/// A host tool tools/<name>.zig with the given src/ modules imported.
fn host_tool(b: *Build, name: []const u8, imports: []const ToolImport) *Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    for (imports) |imp| mod.addImport(imp.name, b.createModule(.{ .root_source_file = b.path(imp.path) }));
    return b.addExecutable(.{ .name = name, .root_module = mod });
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

// ========================================
// Dual boot (docs/DUALBOOT.md)
// ========================================

/// The dual-boot arcade, `snouty-tufty-arcade-supabase.uf2`: the arcade (RAM
/// carts only) in the flash gap 0x1014F000..0x10200000 between the badge's
/// MicroPython binary and its ROMFS. The launcher app
/// (supabase-app/snouty_arcade) reboots into it; its SUPABASE BADGE row
/// reboots back.
///
/// The firmware is linked at 0x10000000, where the bootrom maps the window
/// 0x10150000.. when the launch stub (src/dualboot/stub.S) chains into it.
/// tools/dualboot_uf2.zig packs the launcher sector (header + stub) and the
/// image into a UF2 at the physical addresses and fails the build if any
/// block leaves the gap or the image is over the 704 KB window. Its ELF goes
/// to zig-out/supabase-debug/ only: it carries runtime addresses and must
/// never be flashed as is.
fn add_supabase(b: *Build, mb: *MicroBuild, tufty: *microzig.Target) void {
    const name = "snouty-tufty-arcade-supabase";
    const list_opt = b.option([]const u8, "dualboot_carts", "Carts in snouty-tufty-arcade-supabase.uf2, comma-separated, in menu order (default: every cart of the carts table)");

    var list: std.ArrayList(Cart) = .empty;
    if (list_opt) |names| {
        var it = std.mem.tokenizeAny(u8, names, ", ");
        while (it.next()) |n| {
            const c = for (carts) |c| {
                if (std.mem.eql(u8, c.name, n)) break c;
            } else std.debug.panic("-Ddualboot_carts: unknown cart '{s}' (see the carts table in build.zig)", .{n});
            for (list.items) |have| if (std.mem.eql(u8, have.name, n)) std.debug.panic("-Ddualboot_carts: '{s}' twice", .{n});
            if (c.xip) std.debug.panic("-Ddualboot_carts: '{s}' is an XIP cart; the dual boot holds RAM carts only", .{n});
            list.append(b.allocator, c) catch @panic("OOM");
        }
        if (list.items.len == 0) std.debug.panic("-Ddualboot_carts: no carts", .{});
    } else for (carts) |c| {
        // The arcade's RAM carts only: no XIP cart (Adrian, 2026-10-02).
        if (c.arcade and !c.xip) list.append(b.allocator, c) catch @panic("OOM");
    }
    const bins = b.allocator.alloc(Build.LazyPath, list.items.len) catch @panic("OOM");
    for (list.items, bins) |c, *bin| bin.* = cart_bin(b, c, false);

    // Same RAM layout as the arcade; flash at the runtime base. The linker
    // stops at 1 MB, the packer (with a clearer message) at the 704 KB window.
    var chip = tufty.chip;
    const regions = b.allocator.dupe(@TypeOf(chip.memory_regions[0]), chip.memory_regions) catch @panic("OOM");
    for (regions) |*r| if (r.tag == .flash) {
        r.length = 1024 * 1024;
    };
    chip.memory_regions = regions;
    const target = tufty.derive(.{ .chip = chip });

    const image_files = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "//! Generated by build.zig: the embedded cart images, in menu order.\npub const images = [_][]const u8{\n") catch @panic("OOM");
    for (bins, 0..) |bin, i| {
        _ = image_files.addCopyFile(bin, b.fmt("cart{d}.bin", .{i}));
        src.appendSlice(b.allocator, b.fmt("    @embedFile(\"cart{d}.bin\"),\n", .{i})) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");

    const options = b.addOptions();
    options.addOption(u32, "sys_mhz", 250);
    options.addOption(bool, "arcade", true);
    options.addOption(bool, "supabase", true);

    const fw = mb.add_firmware(.{
        .name = name,
        .target = target,
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/cart_host.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "cart_meta", .module = cart_meta(b, list.items).createModule() },
            .{ .name = "cart_images", .module = b.createModule(.{ .root_source_file = image_files.add("cart_images.zig", src.items) }) },
            .{ .name = "font", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/sycl-badge/src/font.zig") }) },
            .{ .name = "iris_mark", .module = b.createModule(.{ .root_source_file = b.path("snouty-badge/lib/iris_mark.zig") }) },
            .{ .name = "xip_meta", .module = b.createModule(.{ .root_source_file = b.addWriteFiles().add("xip_meta.zig",
                \\//! Generated by build.zig: the dual boot has no XIP cart.
                \\pub const present = false;
                \\pub const image_addr: u32 = 0;
                \\pub const image_len: u32 = 0;
                \\pub const image_crc: u32 = 0;
                \\pub const drive_addr: u32 = 0;
                \\pub const drive_len: u32 = 0;
                \\pub const drive_crc: u32 = 0;
                \\
            ) }) },
        },
    });

    // The launch stub: a position-independent RAM image, linked at 0.
    const stub = b.addExecutable(.{
        .name = "dualboot-stub",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .thumb,
                .os_tag = .freestanding,
                .abi = .eabi,
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    stub.root_module.addAssemblyFile(b.path("src/dualboot/stub.S"));
    stub.setLinkerScript(b.path("src/dualboot/stub.ld"));
    stub.entry = .{ .symbol_name = "stub_start" };
    const stub_bin = b.addObjCopy(stub.getEmittedBin(), .{ .basename = "dualboot-stub.bin", .format = .binary }).getOutput();

    const packer = b.addExecutable(.{
        .name = "dualboot_uf2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dualboot_uf2.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "dualboot", .module = b.createModule(.{ .root_source_file = b.path("src/dualboot.zig") }) }},
        }),
    });
    const run = b.addRunArtifact(packer);
    run.addArg(name);
    run.addFileArg(fw.get_emitted_elf());
    run.addFileArg(stub_bin);
    const uf2 = run.addOutputFileArg(name ++ ".uf2");
    for (list.items, bins) |c, bin| {
        run.addArg(c.name);
        run.addFileArg(bin);
    }
    const report = run.captureStdOut(.{});

    const step = b.step("supabase", "Build only " ++ name ++ ".uf2 (docs/DUALBOOT.md)");
    const installs = [_]*Build.Step{
        &b.addInstallFileWithDir(uf2, .{ .custom = "firmware" }, name ++ ".uf2").step,
        &b.addInstallFileWithDir(report, .{ .custom = "firmware" }, name ++ ".flash.txt").step,
        &b.addInstallFileWithDir(fw.get_emitted_elf(), .{ .custom = "supabase-debug" }, name ++ ".runtime.elf").step,
        &b.addInstallFileWithDir(stub.getEmittedBin(), .{ .custom = "supabase-debug" }, "dualboot-stub.elf").step,
        &b.addInstallFileWithDir(stub_bin, .{ .custom = "supabase-debug" }, "dualboot-stub.bin").step,
    };
    for (installs) |s| {
        step.dependOn(s);
        b.getInstallStep().dependOn(s);
    }

    // The launcher app's logic against this UF2, and the stub emulated (if
    // the unicorn Python module is installed). Needs python3.
    const app_test = b.addSystemCommand(&.{"python3"});
    app_test.addFileArg(b.path("tools/test_supabase_app.py"));
    app_test.addFileArg(uf2);
    app_test.addFileArg(stub_bin);
    b.step("supabase-test", "Host-test the Supabase launcher app and the launch stub (python3)").dependOn(&app_test.step);
}
