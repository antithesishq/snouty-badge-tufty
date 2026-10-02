/// ST7789 driver for the Tufty 2350: 320x240 panel on an 8-bit 8080
/// parallel bus, driven by one PIO state machine fed by one DMA channel.
///
/// A port of Pimoroni's badgeware-cpp st7789.cpp + st7789_parallel.pio
/// (reference/badgeware-cpp-tufty/, MIT). Same init sequence, same MADCTL,
/// same PIO program and clock divider, same "wait for DMA, then wait for the
/// PIO to stall" rule before CS/DC may change.
///
/// Geometry. The panel GRAM is portrait, 240 columns x 320 rows. With
/// MADCTL = ROW_ORDER | SCAN_ORDER, CASET 0..239 and RASET 0..319, RAMWR
/// fills GRAM row by row, and one GRAM row is one *landscape column*:
///   GRAM row r       = landscape x (0 = left edge)
///   GRAM column c    = landscape y (0 = top edge)
/// So a frame is streamed as 320 columns of 240 pixels, x = 0 first, each
/// column top to bottom. Pixels go out as big-endian RGB565 (red in the
/// high bits of the first byte), i.e. a u16 holding @byteSwap(rgb565).
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const gpio = hal.gpio;
const pio_mod = hal.pio;
const dma = hal.dma;
const board = microzig.board;
const time = hal.time;

pub const width: u16 = 320; // landscape
pub const height: u16 = 240; // landscape
pub const column_pixels: u16 = height; // one streamed column

/// Pimoroni's limit for the PIO state machine clock on this panel.
const max_pio_clk_hz: u32 = 44_000_000;

const pio = board.lcd_pio;
const sm: pio_mod.StateMachine = .sm0;
const dma_channel = dma.channel(0);

// The two-instruction 8080 write program, verbatim from
// st7789_parallel.pio. Side-set is WR: `out` puts a byte on D0..D7 with WR
// low, `nop` raises WR, and the panel latches D0..D7 and DC on that edge.
// Autopull refills the OSR every 8 bits.
const st7789_program = blk: {
    @setEvalBranchQuota(10_000);
    break :blk pio_mod.assemble(
        \\.program st7789_parallel
        \\.side_set 1
        \\
        \\.wrap_target
        \\    out pins, 8  side 0
        \\    nop          side 1
        \\.wrap
    , .{}).get_program_by_name("st7789_parallel");
};

const Reg = enum(u8) {
    SWRESET = 0x01,
    SLPOUT = 0x11,
    INVON = 0x21,
    DISPON = 0x29,
    CASET = 0x2A,
    RASET = 0x2B,
    RAMWR = 0x2C,
    TEON = 0x35,
    MADCTL = 0x36,
    COLMOD = 0x3A,
    STE = 0x44,
    RAMCTRL = 0xB0,
    PORCTRL = 0xB2,
    GCTRL = 0xB7,
    VCOMS = 0xBB,
    LCMCTRL = 0xC0,
    VDVVRHEN = 0xC2,
    VRHS = 0xC3,
    VDVS = 0xC4,
    FRCTRL2 = 0xC6,
    PWCTRL1 = 0xD0,
    GMCTRP1 = 0xE0,
    GMCTRN1 = 0xE1,
};

const MADCTL_ROW_ORDER: u8 = 0x80;
const MADCTL_SCAN_ORDER: u8 = 0x10;

// ========================================
// Bus primitives
// ========================================

fn tx_fifo_addr() u32 {
    return @intFromPtr(pio.sm_get_tx_fifo(sm));
}

fn configure_dma(read_increment: bool) void {
    dma_channel.setup_transfer_raw(tx_fifo_addr(), 0, 0, .{
        .trigger = false,
        .enable = true,
        .data_size = .size_8,
        .read_increment = read_increment,
        .write_increment = false,
        .dreq = .pio1_tx0, // = board.lcd_pio (pio1), sm0
    });
}

comptime {
    // The DREQ above is hard-wired to PIO1 SM0.
    std.debug.assert(board.lcd_pio == .pio1);
    std.debug.assert(sm == .sm0);
}

/// Waits until the PIO has clocked out the last byte: clear TXSTALL, then
/// wait for the state machine to stall on the empty FIFO again. Only then is
/// it safe to touch CS or DC (the reference driver's pio_block_until_stalled).
fn wait_pio_stalled() void {
    const regs = pio.get_regs();
    const mask: u32 = @as(u32, 1) << (24 + @as(u5, @backingInt(sm))); // FDEBUG.TXSTALL[sm]
    regs.FDEBUG.write_raw(mask);
    while (regs.FDEBUG.raw & mask == 0) {}
}

fn wait_dma() void {
    dma_channel.wait_for_finish_blocking();
    wait_pio_stalled();
}

fn start_dma(src: [*]const u8, len: u32) void {
    const regs = dma_channel.get_regs();
    regs.trans_count = len;
    regs.al3_read_addr_trig = @intFromPtr(src); // writing the read address starts it
}

fn write_blocking(src: [*]const u8, len: u32) void {
    start_dma(src, len);
    wait_dma();
}

fn command(reg: Reg, data: []const u8) void {
    wait_dma();
    board.lcd_dc.put(0); // command
    board.lcd_cs.put(0);
    const cmd: [1]u8 = .{@intFromEnum(reg)};
    write_blocking(&cmd, 1);
    if (data.len > 0) {
        board.lcd_dc.put(1); // data
        write_blocking(data.ptr, data.len);
    }
    board.lcd_cs.put(1);
}

// ========================================
// Public API
// ========================================

/// PIO clock divider: ceil(2 * max(1, sys / 44 MHz)) / 2, i.e. rounded up
/// to a multiple of 0.5 (exactly the reference's formula). 250 MHz -> 6.0,
/// 150 MHz -> 3.5.
pub fn pio_clkdiv_halves(sys_freq: u32) u32 {
    const halves = (2 * sys_freq + max_pio_clk_hz - 1) / max_pio_clk_hz;
    return @max(2, halves);
}

/// Bring the bus up and run the panel init sequence. The switched power rail
/// (board.sw_power_en) must already be on and settled. Leaves the panel on,
/// GRAM black, backlight off.
pub fn init(sys_freq: u32) void {
    // PIO1 windows GPIO 16..47 so it can reach WR (30) and D0..D7 (32..39).
    // Must happen before any pin mapping (microzig converts GPIO numbers to
    // PIO pin indices using GPIOBASE).
    pio.get_regs().GPIOBASE.write(.{ .GPIOBASE = 1 }); // bit 4 -> base 16
    std.debug.assert(pio.get_gpio_base() == board.lcd_pio_gpio_base);

    // RD, CS, DC: plain SIO outputs. Set the idle level before enabling the
    // driver: RD high (never read), CS high (deselected), DC high (data).
    inline for (.{ board.lcd_rd, board.lcd_cs, board.lcd_dc }) |pin| {
        pin.set_function(.sio);
        pin.put(1);
        pin.set_direction(.out);
    }

    // TE (tearing effect) is a panel output; leave it as a plain input.
    board.lcd_te.set_function(.sio);
    board.lcd_te.set_direction(.in);

    // WR and D0..D7 belong to PIO1.
    pio.gpio_init(board.lcd_wr);
    for (0..board.lcd_data_count) |i| {
        pio.gpio_init(gpio.num(@intCast(@backingInt(board.lcd_d0) + i)));
    }

    const halves = pio_clkdiv_halves(sys_freq);
    const d7 = gpio.num(@intCast(@backingInt(board.lcd_d0) + board.lcd_data_count - 1));
    pio.sm_load_and_start_program(sm, st7789_program, .{
        .clkdiv = .{ .int = @intCast(halves / 2), .frac = if (halves % 2 == 1) 128 else 0 },
        .pin_mappings = .{
            .out = .{ .low = board.lcd_d0, .high = d7 },
            .side_set = .single(board.lcd_wr),
        },
        .shift = .{
            .out_shiftdir = .left, // MSB first; a DMA byte write fills all 4 lanes
            .autopull = true,
            .pull_threshold = 8,
            .join_tx = true,
        },
    }) catch @panic("st7789: PIO setup failed");
    pio.sm_set_pindir(sm, board.lcd_d0, board.lcd_data_count, .out) catch @panic("st7789: pindir");
    pio.sm_set_pindir(sm, board.lcd_wr, 1, .out) catch @panic("st7789: pindir");
    pio.sm_set_enabled(sm, true);

    dma_channel.claim() catch {};
    configure_dma(true);

    init_backlight();
    set_backlight(0);

    // Panel init, byte for byte the stock Tufty 2350 sequence.
    command(.SWRESET, &.{});
    time.sleep_ms(150);

    command(.COLMOD, &.{0x05}); // 16 bpp
    command(.PORCTRL, &.{ 0x0c, 0x0c, 0x00, 0x33, 0x33 });
    command(.LCMCTRL, &.{0x2c});
    command(.VDVVRHEN, &.{0x01});
    command(.VRHS, &.{0x0f});
    command(.VDVS, &.{0x20});
    command(.PWCTRL1, &.{ 0xa4, 0xa1 });
    command(.FRCTRL2, &.{0x0f});
    command(.RAMCTRL, &.{ 0x00, 0xc0 }); // fixes low-brightness green banding
    command(.GCTRL, &.{0x35});
    command(.VCOMS, &.{0x1b});
    command(.GMCTRP1, &.{ 0xF0, 0x00, 0x06, 0x04, 0x05, 0x05, 0x31, 0x44, 0x48, 0x36, 0x12, 0x12, 0x2B, 0x34 });
    command(.GMCTRN1, &.{ 0xF0, 0x0B, 0x0F, 0x0F, 0x0D, 0x26, 0x31, 0x43, 0x47, 0x38, 0x14, 0x14, 0x2C, 0x32 });

    command(.INVON, &.{});
    command(.SLPOUT, &.{});
    time.sleep_ms(100);

    set_window_full();
    command(.MADCTL, &.{MADCTL_ROW_ORDER | MADCTL_SCAN_ORDER});

    // Clear GRAM to black: one zero byte, read increment off.
    const zero: [1]u8 = .{0};
    begin_ramwr();
    configure_dma(false);
    write_blocking(&zero, @as(u32, width) * height * 2);
    configure_dma(true);
    end_frame();

    command(.TEON, &.{0x00}); // TE on, V-blank only
    command(.STE, &.{ 0x00, 0x00 });
    command(.DISPON, &.{});
}

/// Panel address window in landscape coordinates, half-open:
/// columns x0..x1 (GRAM rows), rows y0..y1 (GRAM columns).
pub fn set_window(x0: u16, x1: u16, y0: u16, y1: u16) void {
    std.debug.assert(x0 < x1 and x1 <= width and y0 < y1 and y1 <= height);
    const caset: [4]u8 = .{ @intCast(y0 >> 8), @truncate(y0), @intCast((y1 - 1) >> 8), @truncate(y1 - 1) };
    const raset: [4]u8 = .{ @intCast(x0 >> 8), @truncate(x0), @intCast((x1 - 1) >> 8), @truncate(x1 - 1) };
    command(.CASET, &caset);
    command(.RASET, &raset);
}

pub fn set_window_full() void {
    set_window(0, width, 0, height);
}

fn begin_ramwr() void {
    wait_dma();
    board.lcd_dc.put(0);
    board.lcd_cs.put(0);
    const cmd: [1]u8 = .{@intFromEnum(Reg.RAMWR)};
    write_blocking(&cmd, 1);
    board.lcd_dc.put(1);
}

/// Start a full-screen frame: 320 columns of 240 pixels follow via push().
pub fn begin_frame() void {
    set_window_full();
    begin_ramwr();
}

/// Start a frame into the window set by set_window(x0, x1, y0, y1):
/// (x1 - x0) columns of (y1 - y0) pixels follow via push().
pub fn begin_window(x0: u16, x1: u16, y0: u16, y1: u16) void {
    set_window(x0, x1, y0, y1);
    begin_ramwr();
}

/// Queue one column (or any run) of big-endian RGB565 pixels. Waits for the
/// previous push to finish reading its buffer, then starts the DMA and
/// returns: the caller may fill another buffer meanwhile, but must not touch
/// `pixels` until the next push() or end_frame() returns.
pub fn push(pixels: []const u16) void {
    dma_channel.wait_for_finish_blocking();
    start_dma(@ptrCast(pixels.ptr), @intCast(pixels.len * 2));
}

/// Finish the frame: wait for the last byte to leave the PIO, deselect.
pub fn end_frame() void {
    wait_dma();
    board.lcd_cs.put(1);
}

pub fn is_busy() bool {
    return dma_channel.is_busy();
}

// ========================================
// Backlight (PWM, 16-bit, gamma 2.8 as the reference)
// ========================================

fn init_backlight() void {
    const pwm = hal.pwm.get_pwm(@backingInt(board.lcd_backlight));
    const slice = pwm.slice();
    slice.set_wrap(65535);
    slice.set_clk_div(.{ .int = 1, .frac = 0 });
    pwm.set_level(0);
    slice.enable();
    board.lcd_backlight.set_function(.pwm);
}

/// Backlight brightness 0..255, gamma corrected like the reference driver.
pub fn set_backlight(brightness: u8) void {
    const pwm = hal.pwm.get_pwm(@backingInt(board.lcd_backlight));
    const x: f32 = @as(f32, @floatFromInt(brightness)) / 255.0;
    const level = std.math.pow(f32, x, 2.8) * 65535.0 + 0.5;
    pwm.set_level(@intFromFloat(@min(level, 65535.0)));
}
