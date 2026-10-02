/// Power button: hold it to power the badge off.
///
/// The Tufty's power button is wired to RUN: a press resets the chip, and
/// GPIO 14 (board.reset_sw) reads low for as long as it stays held. So
/// `boot_check`, run first thing in main(), sees a held button and plays
/// the rear-LED sweep (power_sweep.zig); held to the end, the badge powers
/// off. Letting go early boots normally. The same gesture as the stock
/// Badgeware firmware: a port of Pimoroni's powman.c (powman_boot_check,
/// handle_long_press, powman_sleep, powman_off; MIT), docs/POWER.md.
///
/// Off = POWMAN power state P1.7: every domain off but the always-on one,
/// GPIO pads latched in the parked state, so the switched peripheral rail
/// (panel, backlight) drops with its enable pin. What wakes it:
///   * plain hold: a press of A, B, C, UP or DOWN (the switch interrupt
///     line, GPIO 15, on POWMAN wake channel 3), or the power button;
///   * hold with UP + DOWN also held at the end ("shipping mode"): only the
///     power button.
/// Waking is a cold boot of whatever image is at the start of flash.
const microzig = @import("microzig");
const hal = microzig.hal;
const board = microzig.board;
const gpio = hal.gpio;
const time = hal.time;

const buttons = @import("drivers/buttons.zig");
const sweep = @import("power_sweep.zig");
const system = @import("system.zig");

// POWMAN registers (RP2350 datasheet section 6.4; pico-sdk hardware_powman).
// Every write must carry the password 0x5AFE in bits 31:16, the atomic
// set/clear aliases (+0x2000 / +0x3000) included.
const POWMAN_BASE: u32 = 0x40100000;
const PASSWORD: u32 = 0x5AFE_0000;
const VREG_CTRL: u32 = 0x04;
const SEQ_CFG: u32 = 0x34;
const STATE: u32 = 0x38;
const TIMER: u32 = 0x88;
const PWRUP0: u32 = 0x8C; // PWRUP0..3, 4 bytes apart
const DBG_PWRCFG: u32 = 0xA4;
const BOOT0: u32 = 0xD0; // BOOT0..3
const INTE: u32 = 0xE4;

const VREG_CTRL_UNLOCK: u32 = 1 << 13;
const SEQ_CFG_HW_PWRUP_SRAM0: u32 = 1 << 1;
const SEQ_CFG_HW_PWRUP_SRAM1: u32 = 1 << 0;
const STATE_WAITING: u32 = 1 << 12;
const STATE_BAD_SW_REQ: u32 = 1 << 10;
const STATE_REQ_IGNORED: u32 = 1 << 8;
const STATE_REQ_SHIFT = 4;
const TIMER_PWRUP_ON_ALARM: u32 = 1 << 5;
const TIMER_ALARM_ENAB: u32 = 1 << 4;
const INTE_TIMER: u32 = 1 << 1;
const PWRUP_MODE_EDGE: u32 = 1 << 8;
const PWRUP_STATUS: u32 = 1 << 9;
const PWRUP_ENABLE: u32 = 1 << 6;

// The power state written to STATE: one bit per domain, set = on
// (bit 0 SRAM bank 1, 1 SRAM bank 0, 2 XIP cache, 3 switched core).
const off_state: u32 = 0; // P1.7
const wake_channel_switches = 3; // the reference's POWMAN_WAKE_PWRUP3_CH

fn reg(offset: u32) *volatile u32 {
    return @ptrFromInt(POWMAN_BASE + offset);
}
fn write(offset: u32, value: u32) void {
    reg(offset).* = PASSWORD | value;
}
fn set_bits(offset: u32, bits: u32) void {
    reg(offset + 0x2000).* = PASSWORD | bits;
}
fn clear_bits(offset: u32, bits: u32) void {
    reg(offset + 0x3000).* = PASSWORD | bits;
}

// USBCTRL registers, for the PHY low-power setup (pico-sdk hardware_regs/usb.h).
const USBCTRL_BASE: u32 = 0x50110000;
const USB_MAIN_CTRL: u32 = 0x40;
const USB_SIE_CTRL: u32 = 0x4C;
const USB_MUXING: u32 = 0x74;
const USB_PHY_DIRECT: u32 = 0x7C;
const USB_PHY_DIRECT_OVERRIDE: u32 = 0x80;
const USB_INTE: u32 = 0x90;

fn usb_reg(offset: u32) *volatile u32 {
    return @ptrFromInt(USBCTRL_BASE + offset);
}

// Rear case LEDs in sweep order (the reference's {LED_1, LED_2, LED_3, LED_0}).
const sweep_leds = .{ board.case_led_1, board.case_led_2, board.case_led_3, board.case_led_0 };

/// Call first thing in main(): returns at once unless the power button is
/// held. If it is, plays the sweep; released early, it returns (normal
/// boot), held to the end, the badge powers off and this never returns.
pub fn boot_check() void {
    const pin = board.reset_sw;
    pin.set_function(.sio);
    pin.set_direction(.in);
    pin.set_pull(.up);
    time.sleep_us(100);
    if (pin.read() != 0) return;

    buttons.init(); // UP + DOWN pick shipping mode at the end
    leds_pwm_start();
    var n: u32 = 0;
    while (pin.read() == 0) : (n += 1) {
        switch (sweep.frame(n)) {
            .levels => |levels| inline for (sweep_leds, 0..) |led, i| {
                hal.pwm.get_pwm(@backingInt(led)).set_level(levels[i]);
            },
            .done => {
                leds_off();
                const held = buttons.read();
                power_off(!(held.up and held.down));
            },
        }
        time.sleep_ms(sweep.frame_ms);
    }
    leds_off();
}

fn leds_pwm_start() void {
    // GPIO 0..3 = PWM slices 0 and 1. clk_sys / 244 / (wrap + 1) is ~1 kHz
    // at 250 MHz (the reference lands near that too).
    inline for (.{ 0, 1 }) |s| {
        const slice: hal.pwm.Slice = @fromBackingInt(s);
        slice.set_wrap(sweep.wrap);
        slice.set_clk_div(.{ .int = 244, .frac = 0 });
    }
    inline for (sweep_leds) |led| {
        hal.pwm.get_pwm(@backingInt(led)).set_level(0);
        led.set_function(.pwm);
    }
    inline for (.{ 0, 1 }) |s| (@as(hal.pwm.Slice, @fromBackingInt(s))).enable();
}

/// Back to what the rest of the OS expects: plain SIO outputs, low.
fn leds_off() void {
    inline for (.{ 0, 1 }) |s| (@as(hal.pwm.Slice, @fromBackingInt(s))).disable();
    inline for (sweep_leds) |led| {
        led.set_function(.sio);
        led.put(0);
        led.set_direction(.out);
    }
}

/// Park every pin for the lowest draw while off, as the reference's
/// powman_init: inputs with the input buffer off, pulled down, except the
/// PSRAM chip select (up), the user buttons (their pull-ups stay, the
/// switch interrupt line needs them) and the pins with external pulls,
/// which float. GPIO 41 floating drops the switched peripheral rail.
fn park_pins() void {
    for (0..48) |i| {
        const pin = gpio.num(@intCast(i));
        pin.set_function(.sio);
        pin.set_direction(.in);
        pin.set_input_enabled(false);
        switch (i) {
            @backingInt(board.psram_cs) => pin.set_pull(.up),
            @backingInt(board.reset_sw),
            @backingInt(board.button_home),
            @backingInt(board.sw_power_en),
            40,
            42,
            => pin.set_pull(.disabled),
            @backingInt(board.button_a),
            @backingInt(board.button_b),
            @backingInt(board.button_c),
            @backingInt(board.button_up),
            @backingInt(board.button_down),
            => {},
            else => pin.set_pull(.down),
        }
    }
}

/// Reset USBCTRL and park the PHY in its low-power state, as the reference
/// (powered down transceivers, D+/D- pulled down, the PHY under override).
fn usb_phy_low_power() void {
    const usbctrl = hal.resets.Mask.only(.usbctrl);
    hal.resets.reset_block(usbctrl);
    hal.resets.unreset_block_wait(usbctrl);
    usb_reg(USB_MUXING).* = 0x1 | 0x8; // TO_PHY | SOFTCON
    usb_reg(USB_MAIN_CTRL).* = 0x1; // CONTROLLER_EN
    usb_reg(USB_SIE_CTRL).* = 0x2000_0000; // EP0_INT_1BUF
    // BUFF_STATUS, BUS_RESET, SETUP_REQ, DEV_SUSPEND, DEV_RESUME_FROM_HOST, DEV_CONN_DIS
    usb_reg(USB_INTE).* = 0x10 | 0x1000 | 0x1_0000 | 0x4000 | 0x8000 | 0x2000;
    // TX_PD | RX_PD | DM_PULLDN_EN | DP_PULLDN_EN
    usb_reg(USB_PHY_DIRECT).* = 0x2000 | 0x1000 | 0x40 | 0x4;
    // RX_DM/DP/DD and every override enable bit 0..15 but 13 and 14 (bits 0x79FFF)
    usb_reg(USB_PHY_DIRECT_OVERRIDE).* = 0x7_9FFF;
}

/// Wake on a falling edge of the switch interrupt line (any of A, B, C,
/// UP, DOWN), as the reference's powman_setup_gpio_wakeup: wait up to 1 s
/// for the line to go idle first, so the press that is still under a thumb
/// does not count.
fn enable_switch_wakeup() void {
    buttons.init();
    const pin = board.switch_int;
    pin.set_function(.sio);
    pin.set_direction(.in);
    pin.set_pull(.up);
    const deadline = system.micros() + 1_000_000;
    while (pin.read() == 0 and system.micros() < deadline) time.sleep_ms(10);

    const ch = PWRUP0 + 4 * wake_channel_switches;
    write(ch, PWRUP_MODE_EDGE | @as(u32, @backingInt(pin))); // edge, low
    clear_bits(ch, PWRUP_STATUS);
    set_bits(ch, PWRUP_ENABLE);
}

/// Power off: park, arm the wake sources, request P1.7. If POWMAN refuses
/// the request, reboot instead of leaving the board half parked.
fn power_off(wake_on_buttons: bool) noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    park_pins();
    set_bits(VREG_CTRL, VREG_CTRL_UNLOCK);
    usb_phy_low_power();
    set_bits(DBG_PWRCFG, 1); // ignore a debugger's power-up request

    // Clear any wake source an earlier firmware left armed (POWMAN keeps its
    // registers across a watchdog reboot), then arm ours.
    for (0..4) |i| clear_bits(PWRUP0 + 4 * @as(u32, @intCast(i)), PWRUP_ENABLE);
    clear_bits(INTE, INTE_TIMER);
    clear_bits(TIMER, TIMER_ALARM_ENAB | TIMER_PWRUP_ON_ALARM);
    if (wake_on_buttons) enable_switch_wakeup();

    // powman_configure_wakeup_state(P1.7, P0.3): the SRAM banks are off
    // while asleep, so the hardware powers them up on the way back.
    set_bits(SEQ_CFG, SEQ_CFG_HW_PWRUP_SRAM0 | SEQ_CFG_HW_PWRUP_SRAM1);
    // A plain cold boot on wake, not a POWMAN boot vector.
    inline for (0..4) |i| reg(BOOT0 + 4 * i).* = 0;

    if (request_off()) {
        while (true) asm volatile ("wfi");
    }
    system.reboot_normal();
}

/// powman_set_power_state(P1.7): true once POWMAN waits for the
/// processors to sleep.
fn request_off() bool {
    clear_bits(STATE, STATE_REQ_IGNORED);
    write(STATE, (~off_state << STATE_REQ_SHIFT) & 0xF0);
    const state = reg(STATE).*;
    if (state & (STATE_REQ_IGNORED | STATE_BAD_SW_REQ) != 0) return false;
    for (0..100) |_| {
        if (reg(STATE).* & STATE_WAITING != 0) return true;
    }
    return false;
}
