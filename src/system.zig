/// Small board services shared by the hello app and the cart host:
/// the switched power rail, a microsecond clock, the HOME button
/// short/long press logic, and the reboot into BOOTSEL.
const microzig = @import("microzig");
const hal = microzig.hal;
const board = microzig.board;
const time = hal.time;

const home_logic = @import("home.zig");
pub const HomeButton = home_logic.HomeButton;

/// Drive the switched peripheral rail (panel, backlight, RTC) high and let
/// it settle, as the reference board.cpp does (50 ms).
pub fn power_on_peripherals() void {
    const pin = board.sw_power_en;
    pin.set_function(.sio);
    pin.put(1);
    pin.set_direction(.out);
    time.sleep_ms(50);
}

/// Microseconds since boot (TIMER0, ticking at 1 MHz from clk_ref).
pub fn micros() u64 {
    return hal.system_timer.num(0).read();
}

/// Reboot into the RP2350 bootrom's USB mass-storage / PICOBOOT mode, so a
/// new UF2 can be dropped on without the button dance. Uses the bootrom
/// `reboot` function (REBOOT2_FLAG_REBOOT_TYPE_BOOTSEL, no return).
pub fn reboot_to_bootsel() noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    hal.rom.reset_to_usb_boot();
    while (true) {}
}
