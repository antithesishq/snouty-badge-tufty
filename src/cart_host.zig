/// Tufty OS: runs unmodified SYCL Badge RAM carts. M1 embeds one cart and
/// boots it; M2 (the arcade, `build_options.arcade`) embeds every cart of
/// build.zig's `carts` table and boots into a menu (menu.zig, arcade.zig).
///
/// Core 0 (this file) is the OS: it copies the embedded cart image into
/// cart RAM, starts core 1 at the cart's entry point exactly as the SYCL OS
/// does (sycl-badge src/os/cart.zig executeCart), then serves the cart ABI:
///   - Controls: Tufty buttons mapped per cart (controls_map.zig) into the
///     IPC block every loop.
///   - Present: on FRAMEBUFFER_READY(_V2) it scales the 160x128 cart
///     framebuffer onto the 320x240 panel column by column (scaler.zig),
///     honours vsync_frame_ms pacing, then answers FRAMEBUFFER_DONE.
///   - SYNC_TIME handshake (the cart's _start does it before start()).
///   - Tone, volume, trace, neopixels and the red LED are accepted and
///     ignored (the Tufty has no buzzer the carts could use).
/// HOME: short press restarts the cart (single-cart build) or stops it and
/// returns to the menu (arcade); held 1 s reboots into BOOTSEL.
///
/// Arcade menu: core 1 is held in reset, core 0 streams the menu to the
/// panel column by column (no framebuffer) and redraws only on a change.
///
/// RAM: the OS lives in 0x20000000..0x20020000 (the linker region is cut to
/// 128 KB in build.zig). 0x20020000..0x20080000 is the cart's: IPC block,
/// then the cart image at 0x20035100, its BSS/heap, its stack at the top.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const fifo = hal.multicore.fifo;

const build_options = @import("build_options");
const cart_meta = @import("cart_meta");
const cart_images = @import("cart_images").images;

const clocks = @import("clocks.zig");
const st7789 = @import("drivers/st7789.zig");
const buttons = @import("drivers/buttons.zig");
const system = @import("system.zig");
const scaler = @import("scaler.zig");
const controls_map = @import("controls_map.zig");
const abi = @import("os/abi.zig");
const cart_image = @import("os/cart_image.zig");
const arcade = @import("arcade.zig");
const menu = @import("menu.zig");

comptime {
    _ = microzig.export_startup();
}

pub const init = clocks.init;

/// One embedded cart: its image, scale mode and button map (by name, from
/// controls_map.for_cart), as the generated table lists them.
const Slot = struct {
    bytes: []const u8,
    scale: scaler.Mode,
    map: *const controls_map.Map,
};

const cart_count = cart_images.len;

const slots: [cart_count]Slot = blk: {
    if (cart_count == 0 or cart_count > arcade.max_carts) @compileError("1..32 carts");
    if (cart_meta.names.len != cart_count) @compileError("cart_meta and cart_images disagree");
    var s: [cart_count]Slot = undefined;
    for (&s, cart_images, cart_meta.names, cart_meta.scales) |*slot, bytes, name, scale| {
        slot.* = .{
            .bytes = bytes,
            .scale = std.meta.stringToEnum(scaler.Mode, scale) orelse @compileError("scale must be fit, crop or native"),
            .map = controls_map.for_cart(name),
        };
    }
    break :blk s;
};

/// Button mapper state and the number of cart presents (pulse stretching
/// counts presents, not OS loops).
var mapper: controls_map.Mapper = undefined;
var presents: u32 = 0;

const backlight_level: u8 = 230; // ~90%

/// Constant sensor readings for the cart (12-bit, as the SYCL ADC).
const light_level_constant: u16 = 0x800;
const battery_level_constant: u16 = 0xFFF;

var maps: scaler.Maps = undefined;
var column_bufs: [2][st7789.column_pixels]u16 = undefined;

// ========================================
// Cart launch
// ========================================

/// Entry point for core 1, read by core1_main after launch.
var cart_entry: u32 = 0;

fn ram(start: u32, end: u32) []u8 {
    const p: [*]u8 = @ptrFromInt(start);
    return p[0 .. end - start];
}

/// Stops the cart, leaving core 1 held in reset. Safe at any point of the
/// cart's life, because core 0 only gets here between loop iterations:
///   - The panel is idle. present() is synchronous on core 0 and ends with
///     end_frame() (DMA channel 0 done, PIO stalled, CS high), so a stop
///     never cuts a panel transfer.
///   - Core 1 is forced off (PSM FRCE_OFF.PROC1) and stays off until the
///     next launch_core1, which resets it again and runs the bootrom
///     handshake.
///   - DMA channels 1..15 (anything the cart started) are aborted, and the
///     SIO spinlock its tracy code takes is freed.
///   - The cart -> OS FIFO is drained and its sticky error flags cleared;
///     a present the cart had queued is dropped (pending = null), so no
///     FRAMEBUFFER_DONE is ever sent to a cart that is gone.
fn stop_cart() void {
    microzig.chip.peripherals.PSM.FRCE_OFF.modify(.{ .PROC1 = 1 });
    while (microzig.chip.peripherals.PSM.FRCE_OFF.read().PROC1 != 1) {}

    // RP2350 CHAN_ABORT is at DMA + 0x464 (pico-sdk regs/dma.h; the SYCL
    // OS's 0x444 is the RP2040 offset). Channel 0 is the panel's.
    const DMA_CHAN_ABORT: *volatile u32 = @ptrFromInt(0x5000_0464);
    DMA_CHAN_ABORT.* = 0xFFFE;
    while (DMA_CHAN_ABORT.* & 0xFFFE != 0) {}
    @as(*volatile u32, @ptrFromInt(abi.tracy_spinlock_addr)).* = 0;

    fifo.drain();
    // FIFO_ST: writing clears the sticky ROE (read on empty) / WOF (write
    // on full) flags (RP2350 datasheet, SIO FIFO_ST).
    microzig.chip.peripherals.SIO.FIFO_ST.write_raw(0xFF);

    reset_present_state();
}

/// Stops whatever runs, rebuilds cart RAM from cart `index`'s image and
/// starts it on core 1 with that cart's scale and button map. Used at boot,
/// for a HOME restart and for every arcade launch.
fn start_cart(index: u8) void {
    const slot = &slots[index];
    const info = infos[index] orelse return;

    // Hold core 1 in reset while its RAM is rewritten.
    stop_cart();

    // Fresh cart RAM: zero everything (IPC block, BSS, heap, stack), then
    // copy the image to its link address. BSS is zeroed again per the
    // descriptor, as the SYCL loader does.
    @memset(ram(abi.process_ram_start, abi.process_ram_end), 0);
    @memcpy(ram(abi.cart_ram_origin, abi.cart_ram_origin + @as(u32, @intCast(slot.bytes.len))), slot.bytes);
    @memset(ram(info.bss_start, info.bss_end), 0);

    maps = scaler.Maps.init(slot.scale);
    // Black the panel first: a native-scale cart never draws the border,
    // and a dirty-rect cart may never repaint all of it.
    clear_panel();

    mapper = .init(slot.map);
    presents = 0;
    const ipc = abi.ipc();
    ipc.controls = @bitCast(mapper.update(session.cart_buttons(buttons.read().bits()), system.micros(), presents));
    ipc.light_level = light_level_constant;
    ipc.battery_level = battery_level_constant;

    @as(*volatile u32, &cart_entry).* = info.entry_point;
    asm volatile ("dsb" ::: .{ .memory = true });

    // Resets core 1 again, drains the FIFO, runs core1_main on core 1.
    hal.multicore.launch_core1(core1_main);
}

/// Runs on core 1 (microzig's launch wrapper has enabled the FPU). Prepares
/// the core like the SYCL OS's executeCart for a RAM cart, then jumps to
/// the cart with MSP at the top of cart RAM. Never returns.
fn core1_main() void {
    asm volatile ("cpsid i");

    // Disable and clear all external IRQs, SysTick, pending PendSV/SysTick
    // and sticky fault status (os/cart.zig clearCore1InterruptAndFaultState).
    @as(*volatile u32, @ptrFromInt(0xE000E180)).* = 0xFFFF_FFFF; // NVIC_ICER0
    @as(*volatile u32, @ptrFromInt(0xE000E184)).* = 0xFFFF_FFFF; // NVIC_ICER1
    @as(*volatile u32, @ptrFromInt(0xE000E280)).* = 0xFFFF_FFFF; // NVIC_ICPR0
    @as(*volatile u32, @ptrFromInt(0xE000E284)).* = 0xFFFF_FFFF; // NVIC_ICPR1
    @as(*volatile u32, @ptrFromInt(0xE000E010)).* = 0; // SYST_CSR
    @as(*volatile u32, @ptrFromInt(0xE000ED04)).* = (1 << 27) | (1 << 25); // ICSR PENDSVCLR | PENDSTCLR
    @as(*volatile u32, @ptrFromInt(0xE000ED28)).* = 0xFFFF_FFFF; // CFSR
    @as(*volatile u32, @ptrFromInt(0xE000ED2C)).* = 0xFFFF_FFFF; // HFSR
    @as(*volatile u32, @ptrFromInt(0xE000ED30)).* = 0xFFFF_FFFF; // DFSR

    // Cycle counter for the cart's cycles(): DEMCR.TRCENA, DWT_CTRL.CYCCNTENA.
    const DEMCR: *volatile u32 = @ptrFromInt(0xE000EDFC);
    DEMCR.* = DEMCR.* | (1 << 24);
    const DWT_CTRL: *volatile u32 = @ptrFromInt(0xE0001000);
    DWT_CTRL.* = DWT_CTRL.* | 1;

    // FPU: lazy state preservation, full CP access (as the SYCL OS).
    const FPCCR: *volatile u32 = @ptrFromInt(0xE000EF34);
    FPCCR.* = FPCCR.* | (1 << 31) | (1 << 30);
    @as(*volatile u32, @ptrFromInt(0xE000ED88)).* = 0xFFFF_FFFF; // CPACR

    const entry = @as(*volatile u32, &cart_entry).*;
    asm volatile (
        \\  dsb
        \\  isb
        \\  msr msp, %[sp]
        \\  dsb
        \\  isb
        \\  bx %[entry]
        :
        : [sp] "r" (abi.cart_initial_sp),
          [entry] "r" (entry),
        : .{ .memory = true });
    unreachable;
}

// ========================================
// Present
// ========================================

const Pending = struct { index: u1, rect: scaler.Rect };

var pending: ?Pending = null;
var vsync_on: bool = false;
var frame_us: u32 = 0;
var next_due_us: u64 = 0;

fn reset_present_state() void {
    pending = null;
    vsync_on = false;
    frame_us = 0;
    next_due_us = 0;
}

fn clip_rect(r: abi.Rect8) scaler.Rect {
    return .{
        .min_x = @min(r.min_x, abi.screen_width),
        .min_y = @min(r.min_y, abi.screen_height),
        .max_x = @min(r.max_x, abi.screen_width),
        .max_y = @min(r.max_y, abi.screen_height),
    };
}

const empty_rect: scaler.Rect = .{ .min_x = abi.screen_width, .min_y = abi.screen_height, .max_x = 0, .max_y = 0 };

fn handle_message(msg: u32) void {
    const ipc = abi.ipc();
    if (msg == abi.FRAMEBUFFER_READY) {
        presents +%= 1;
        pending = .{ .index = 0, .rect = .all };
        return;
    }
    switch (abi.msg_type(msg)) {
        abi.TYPE_FRAMEBUFFER_READY_V2 => {
            const flags: abi.PresentFlags = @bitCast(msg);
            presents +%= 1;
            if (flags.vsync_updated) {
                vsync_on = ipc.vsync_flags != 0;
                const ms = ipc.vsync_frame_ms;
                frame_us = if (ms > 0 and ms < 1000) @intFromFloat(ms * 1000.0) else 0;
                next_due_us = 0;
            }
            // V2 without a dirty rect means "nothing changed" (kernel.zig).
            // clear_frame: the SYCL OS ignores it too (cart clears itself).
            pending = .{
                .index = flags.framebuffer_index,
                .rect = if (flags.has_dirty_rect) clip_rect(ipc.dirty_rect) else empty_rect,
            };
        },
        abi.TYPE_TRACE, abi.TYPE_TONE, abi.TYPE_VOLUME => {}, // accepted, ignored
        else => if (msg == abi.SYNC_TIME_REQ_CLR) sync_time(),
    }
}

/// The cart's os_align_cycles(): ACK_CLR, wait for REQ_TIME, then send a
/// 64-bit core-0 time (high word, low word). The value only aligns tracy
/// timestamps; we send microseconds scaled to cycles.
fn sync_time() void {
    fifo.write_blocking(abi.SYNC_TIME_ACK_CLR);
    const deadline = system.micros() + 100_000;
    while (system.micros() < deadline) {
        const msg = fifo.read() orelse continue;
        if (msg != abi.SYNC_TIME_REQ_TIME) continue;
        const t: u64 = system.micros() * clocks.sys_mhz;
        fifo.write_blocking(@truncate(t >> 32));
        fifo.write_blocking(@truncate(t));
        return;
    }
}

/// Streams one cart framebuffer (the dirty part) to the panel.
fn present(p: Pending) void {
    const win = scaler.window_for(&maps, p.rect) orelse return;
    const fbs: *const [2][abi.screen_width][abi.screen_height]u16 = @volatileCast(&abi.ipc().framebuffers);
    const fb = &fbs[p.index];
    const rows = win.y1 - win.y0;

    st7789.begin_window(win.x0, win.x1, win.y0, win.y1);
    var last_sx: u16 = 0xFFFF;
    var which: u1 = 0;
    var dx = win.x0;
    while (dx < win.x1) : (dx += 1) {
        const sx = maps.x[dx];
        if (sx != last_sx) {
            // A new cart column: convert it into the buffer not on the bus.
            which ^= 1;
            const buf = column_bufs[which][0..rows];
            if (sx == scaler.none) @memset(buf, 0) else scaler.fill_column(&fb[sx], &maps.y, win.y0, win.y1, buf);
            last_sx = sx;
        }
        st7789.push(column_bufs[which][0..rows]);
    }
    st7789.end_frame();
}

fn service_present(now: u64) void {
    const p = pending orelse return;
    if (vsync_on and frame_us > 0 and next_due_us != 0 and now < next_due_us) return;

    present(p);
    pending = null;
    fifo.write_blocking(abi.FRAMEBUFFER_DONE);

    if (vsync_on and frame_us > 0) {
        next_due_us = if (next_due_us == 0 or now > next_due_us + frame_us) now + frame_us else next_due_us + frame_us;
    }
}

// ========================================
// Main
// ========================================

/// Shown instead of the cart if the embedded image is unusable.
fn fail_screen(color: u16) noreturn {
    st7789.begin_frame();
    @memset(&column_bufs[0], color);
    for (0..st7789.width) |_| st7789.push(&column_bufs[0]);
    st7789.end_frame();
    var home: system.HomeButton = .{};
    while (true) {
        if (home.update(buttons.read().home, system.micros()) == .long_press) system.reboot_to_bootsel();
    }
}

fn fail_color(err: cart_image.Error) u16 {
    return switch (err) {
        error.ImageTooLarge => 0x00F8, // red (big-endian RGB565)
        error.NoDescriptor => 0xE0FF, // yellow
        error.BadVersion => 0x1FF8, // magenta
        error.BadBss, error.BadEntry => 0x1F00, // blue
    };
}

/// Fills the whole panel with black.
fn clear_panel() void {
    st7789.begin_frame();
    @memset(&column_bufs[0], 0);
    for (0..st7789.width) |_| st7789.push(&column_bufs[0]);
    st7789.end_frame();
}

/// Streams the menu (core 1 stopped, so core 0 owns the panel).
fn draw_menu() void {
    const view: menu.View = .{
        .titles = cart_meta.titles,
        .blurbs = cart_meta.blurbs,
        .cursor = session.cursor,
        .playable = session.playable,
    };
    var layout: menu.Layout = .{};
    layout.build(&view);
    st7789.begin_frame();
    for (0..menu.width) |x| {
        const buf = &column_bufs[x & 1];
        menu.render_column(@intCast(x), &view, &layout, buf);
        st7789.push(buf);
    }
    st7789.end_frame();
}

/// Validated image of every cart (null: unusable, never launched).
var infos: [cart_count]?cart_image.Info = @splat(null);
var session: arcade.Session = undefined;

fn exec(cmd: arcade.Command) void {
    switch (cmd) {
        .none => {},
        .redraw => draw_menu(),
        .stop_to_menu => {
            stop_cart();
            draw_menu();
        },
        .launch => |i| start_cart(i),
        .bootsel => system.reboot_to_bootsel(),
    }
}

pub noinline fn main() void {
    system.power_on_peripherals();
    buttons.init();
    st7789.init(clocks.sys_freq);
    st7789.set_backlight(backlight_level);

    var playable: u32 = 0;
    for (&slots, &infos, 0..) |*slot, *info, i| {
        if (cart_image.validate(slot.bytes, abi.cart_ram_origin)) |ok| {
            info.* = ok;
            playable |= @as(u32, 1) << @intCast(i);
        } else |err| {
            // The single-cart build shows the error colour, as M1 did; the
            // arcade dims the cart in the menu instead.
            if (!build_options.arcade) fail_screen(fail_color(err));
        }
    }

    session = .init(cart_count, build_options.arcade, playable);
    exec(session.boot(buttons.read().bits()));

    while (true) {
        const held = buttons.read();
        const now = system.micros();
        const was_running = session.screen == .cart;

        // Controls first, as M1: the cart sees this loop's buttons.
        if (was_running) abi.ipc().controls = @bitCast(mapper.update(session.cart_buttons(held.bits()), now, presents));

        const cmd = session.update(held.bits(), held.home, now);
        exec(cmd);
        if (cmd != .none or session.screen != .cart) continue;

        while (fifo.read()) |msg| handle_message(msg);
        service_present(system.micros());
    }
}
