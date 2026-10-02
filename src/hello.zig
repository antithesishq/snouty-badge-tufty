/// Snouty Tufty M0: bare-metal bring-up for the Tufty 2350.
///
/// Clocks (250 MHz by default), switched power rail, ST7789 over PIO + DMA,
/// a test screen streamed column by column (no framebuffer), live button
/// boxes, frame counter and fps. Hold HOME for 1 s to reboot into BOOTSEL.
const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const board = microzig.board;
const time = hal.time;

const clocks = @import("clocks.zig");
const st7789 = @import("drivers/st7789.zig");
const buttons = @import("drivers/buttons.zig");
const pattern = @import("pattern.zig");
const system = @import("system.zig");
const power = @import("power.zig");

comptime {
    _ = microzig.export_startup();
}

/// Root `init` replaces the HAL's default (150 MHz) clock setup.
pub const init = clocks.init;

/// Backlight level, ~90%.
const backlight_level: u8 = 230;

// Two column buffers: one is filled while the other is on the bus.
var column_bufs: [2][st7789.column_pixels]u16 = undefined;

pub noinline fn main() void {
    power.boot_check();
    system.power_on_peripherals();
    buttons.init();
    st7789.init(clocks.sys_freq);
    st7789.set_backlight(backlight_level);

    var st: pattern.State = .{ .sys_mhz = clocks.sys_mhz };
    var lines: pattern.Lines = .{};
    var home: system.HomeButton = .{};

    var fps_window_start = system.micros();
    var fps_window_frames: u32 = 0;

    while (true) {
        const held = buttons.read();
        st.held = .{ held.a, held.b, held.c, held.up, held.down, held.home };

        switch (home.update(held.home, system.micros())) {
            .none => {},
            .short_press => st.home_presses += 1,
            .long_press => system.reboot_to_bootsel(),
        }

        lines.build(&st);
        st7789.begin_frame();
        for (0..pattern.width) |x| {
            const buf = &column_bufs[x & 1];
            pattern.render_column(@intCast(x), &st, &lines, buf);
            st7789.push(buf);
        }
        st7789.end_frame();

        st.frame +%= 1;
        fps_window_frames += 1;
        const now = system.micros();
        const elapsed = now - fps_window_start;
        if (elapsed >= 1_000_000) {
            st.fps_x10 = @intCast(@as(u64, fps_window_frames) * 10_000_000 / elapsed);
            fps_window_start = now;
            fps_window_frames = 0;
        }
    }
}
