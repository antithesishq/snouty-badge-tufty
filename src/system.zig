/// Small board services shared by the hello app and the cart host:
/// the switched power rail, a microsecond clock, the HOME button
/// short/long press logic, and the reboots into BOOTSEL and into the
/// normal boot path.
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

/// Reboot into the normal boot path: the bootrom boots whatever image is
/// at the start of flash. In the dual-boot build that is the badge's own
/// MicroPython firmware (docs/DUALBOOT.md). Uses the bootrom `reboot`
/// function (REBOOT2_FLAG_REBOOT_TYPE_NORMAL | NO_RETURN_ON_SUCCESS, p0 = 0:
/// the boot diagnostic partition), which resets everything but the
/// processor cold domain through the watchdog, QMI address translation
/// included.
pub fn reboot_normal() noreturn {
    microzig.cpu.interrupt.disable_interrupts();
    const reboot: *const hal.rom.signatures.reboot = @ptrCast(@alignCast(hal.rom.lookup_function(.reboot)));
    _ = reboot(0x0000 | 0x0100, 10, 0, 0);
    while (true) {}
}
