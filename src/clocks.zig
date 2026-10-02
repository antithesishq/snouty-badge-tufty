/// System clock bring-up for the Tufty 2350.
///
/// The stock Tufty firmware (Pimoroni badgeware, pimoroni_tufty2350.h) runs
/// clk_sys at 250 MHz: VREG 1.20 V, PLL_SYS VCO 1500 MHz (12 MHz x 125),
/// postdiv1 6, postdiv2 1. We do the same: raise the core voltage first,
/// then let microzig's normal init sequence apply our clock config.
///
/// `build_options.sys_mhz` picks the clock: 250 (stock Tufty) or 150
/// (microzig's default preset, VREG left at its 1.10 V reset value).
const microzig = @import("microzig");
const hal = microzig.hal;
const clocks = hal.clocks;
const build_options = @import("build_options");

pub const sys_mhz: u32 = build_options.sys_mhz;
pub const sys_freq: u32 = sys_mhz * 1_000_000;

const xosc_freq = microzig.board.xosc_freq;

/// 250 MHz: same as Pimoroni's SDK board config. clk_ref = XOSC 12 MHz,
/// clk_sys = PLL_SYS 250 MHz, clk_usb/clk_adc = PLL_USB 48 MHz,
/// clk_peri = clk_hstx = clk_sys (the pico-sdk's runtime_init_clocks does
/// exactly this for any SYS_CLK_HZ).
const config_250: clocks.config.Global = .{
    .ref = .{ .input = .{ .source = .src_xosc, .freq = xosc_freq }, .integer_divisor = 1 },
    .pll_sys = .{ .refdiv = 1, .fbdiv = 125, .postdiv1 = 6, .postdiv2 = 1 },
    .pll_usb = .{ .refdiv = 1, .fbdiv = 40, .postdiv1 = 5, .postdiv2 = 2 },
    .sys = .{ .input = .{ .source = .pll_sys, .freq = 250_000_000 }, .integer_divisor = 1 },
    .usb = .{ .input = .{ .source = .pll_usb, .freq = 48_000_000 }, .integer_divisor = 1 },
    .adc = .{ .input = .{ .source = .pll_usb, .freq = 48_000_000 }, .integer_divisor = 1 },
    .hstx = .{ .input = .{ .source = .clk_sys, .freq = 250_000_000 }, .integer_divisor = 1 },
    .peri = .{ .input = .{ .source = .clk_sys, .freq = 250_000_000 }, .integer_divisor = 1 },
};

pub const clock_config: clocks.config.Global = switch (sys_mhz) {
    250 => config_250,
    150 => clocks.config.preset.default(),
    else => @compileError("sys_mhz must be 150 or 250"),
};

comptime {
    if (clock_config.get_frequency(.clk_sys).? != sys_freq)
        @compileError("clock config does not produce sys_freq");
}

// POWMAN registers (RP2350 datasheet section 6.4; pico-sdk hardware_vreg).
// Every POWMAN write must carry the password 0x5AFE in bits 31:16.
const POWMAN_BASE: u32 = 0x40100000;
const POWMAN_PASSWORD: u32 = 0x5AFE_0000;
const VREG_CTRL: *volatile u32 = @ptrFromInt(POWMAN_BASE + 0x04);
const VREG_CTRL_SET: *volatile u32 = @ptrFromInt(POWMAN_BASE + 0x04 + 0x2000); // atomic set alias
const VREG: *volatile u32 = @ptrFromInt(POWMAN_BASE + 0x0C);
const VREG_CTRL_UNLOCK: u32 = 1 << 13;
const VREG_VSEL_MASK: u32 = 0x1F << 4;
const VREG_UPDATE_IN_PROGRESS: u32 = 1 << 15;
const VSEL_1V20: u32 = 0b01101; // VREG_VOLTAGE_1_20, Pimoroni's BW_VREG_VOLTAGE

/// Mirrors pico-sdk vreg_set_voltage() on RP2350: unlock the VREG control
/// interface, wait out any update in progress, write VSEL, wait again.
fn set_vreg_1v20() void {
    VREG_CTRL_SET.* = POWMAN_PASSWORD | VREG_CTRL_UNLOCK;

    while (VREG.* & VREG_UPDATE_IN_PROGRESS != 0) {}
    const current = VREG.* & 0xFFFF & ~VREG_VSEL_MASK;
    VREG.* = POWMAN_PASSWORD | current | (VSEL_1V20 << 4);
    while (VREG.* & VREG_UPDATE_IN_PROGRESS != 0) {}

    // The SDK waits SYS_CLK_VREG_VOLTAGE_AUTO_ADJUST_DELAY_US (1 ms) for the
    // rail to settle. The timer is not ticking yet, so count cycles: the boot
    // clock is at most 150 MHz and each iteration is at least 2 cycles, so
    // 150_000 iterations is at least 2 ms.
    var i: u32 = 0;
    while (i < 150_000) : (i += 1) {
        asm volatile ("nop");
    }
}

/// Called by microzig before main() (root `init` overrides the HAL default).
pub fn init() void {
    if (sys_mhz > 150) set_vreg_1v20();
    hal.init_sequence(clock_config);
}
