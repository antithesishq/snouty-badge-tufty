/// Tufty OS, M1: runs one unmodified SYCL Badge RAM cart.
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
/// HOME: short press restarts the cart, held 1 s reboots into BOOTSEL.
///
/// RAM: the OS lives in 0x20000000..0x20020000 (the linker region is cut to
/// 128 KB in build.zig). 0x20020000..0x20080000 is the cart's: IPC block,
/// then the cart image at 0x20035100, its BSS/heap, its stack at the top.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const fifo = hal.multicore.fifo;

const build_options = @import("build_options");
const cart_bytes: []const u8 = @import("cart_image").bytes;

const clocks = @import("clocks.zig");
const st7789 = @import("drivers/st7789.zig");
const buttons = @import("drivers/buttons.zig");
const system = @import("system.zig");
const scaler = @import("scaler.zig");
const controls_map = @import("controls_map.zig");
const abi = @import("os/abi.zig");
const cart_image = @import("os/cart_image.zig");

comptime {
    _ = microzig.export_startup();
}

pub const init = clocks.init;

const cart_name = build_options.cart_name;
const scale_mode: scaler.Mode = std.meta.stringToEnum(scaler.Mode, build_options.scale) orelse
    @compileError("-Dscale must be fit, crop or native");
const button_map: *const controls_map.Map = controls_map.for_cart(cart_name);

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

/// Stops core 1, rebuilds cart RAM from the image and starts the cart.
/// Used at boot and for a HOME restart.
fn start_cart(info: cart_image.Info) void {
    // Hold core 1 in reset while its RAM is rewritten.
    microzig.chip.peripherals.PSM.FRCE_OFF.modify(.{ .PROC1 = 1 });
    while (microzig.chip.peripherals.PSM.FRCE_OFF.read().PROC1 != 1) {}

    // Stop any DMA the cart left running (channel 0 is the panel's) and
    // free the SIO spinlock its tracy code uses.
    // RP2350 CHAN_ABORT is at DMA + 0x464 (pico-sdk regs/dma.h; the SYCL
    // OS's 0x444 is the RP2040 offset).
    const DMA_CHAN_ABORT: *volatile u32 = @ptrFromInt(0x5000_0464);
    DMA_CHAN_ABORT.* = 0xFFFE;
    while (DMA_CHAN_ABORT.* & 0xFFFE != 0) {}
    @as(*volatile u32, @ptrFromInt(abi.tracy_spinlock_addr)).* = 0;

    // Fresh cart RAM: zero everything (IPC block, BSS, heap, stack), then
    // copy the image to its link address. BSS is zeroed again per the
    // descriptor, as the SYCL loader does.
    @memset(ram(abi.process_ram_start, abi.process_ram_end), 0);
    @memcpy(ram(abi.cart_ram_origin, abi.cart_ram_origin + @as(u32, @intCast(cart_bytes.len))), cart_bytes);
    @memset(ram(info.bss_start, info.bss_end), 0);

    mapper = .init(button_map);
    presents = 0;
    const ipc = abi.ipc();
    ipc.controls = @bitCast(mapper.update(buttons.read().bits() & 0x1F, system.micros(), presents));
    ipc.light_level = light_level_constant;
    ipc.battery_level = battery_level_constant;

    reset_present_state();

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

pub noinline fn main() void {
    system.power_on_peripherals();
    buttons.init();
    st7789.init(clocks.sys_freq);
    st7789.set_backlight(backlight_level);
    maps = scaler.Maps.init(scale_mode);

    const info = cart_image.validate(cart_bytes, abi.cart_ram_origin) catch |err| fail_screen(switch (err) {
        error.ImageTooLarge => 0x00F8, // red (big-endian RGB565)
        error.NoDescriptor => 0xE0FF, // yellow
        error.BadVersion => 0x1FF8, // magenta
        error.BadBss, error.BadEntry => 0x1F00, // blue
    });

    start_cart(info);

    var home: system.HomeButton = .{};
    while (true) {
        const held = buttons.read();
        abi.ipc().controls = @bitCast(mapper.update(held.bits() & 0x1F, system.micros(), presents));

        switch (home.update(held.home, system.micros())) {
            .none => {},
            .short_press => {
                start_cart(info);
                continue;
            },
            .long_press => system.reboot_to_bootsel(),
        }

        while (fifo.read()) |msg| handle_message(msg);
        service_present(system.micros());
    }
}
