/// The power-button long-press LED sweep (pure, host-tested).
///
/// A port of the sweep in Pimoroni badgeware's powman.c (handle_long_press,
/// MIT): the four rear case LEDs fade in one after another, then fade out
/// together; if the button is still held when they are all dark, the badge
/// powers off. One frame every `frame_ms`.
const std = @import("std");

pub const frame_ms: u32 = 5;

const peak: i32 = 150;
const in_phase: i32 = 30;
const out_phase: i32 = 0;
const total: i32 = peak + in_phase * 3;
const fadeout_speed: i32 = 5;
const on_delay_frames: i32 = 200 / frame_ms;

/// PWM levels (out of `wrap`) for the LEDs in sweep order, or `done`.
pub const Frame = union(enum) {
    levels: [4]u16,
    done,
};

/// The PWM wrap the levels are scaled for.
pub const wrap: u16 = 1024;

pub fn frame(n: u32) Frame {
    const br: i32 = @intCast(@min(n, 100_000));
    const cbr = if (br < on_delay_frames) 0 else br - on_delay_frames;
    var o = if (cbr >= total) total - (cbr - total) * fadeout_speed else cbr;
    const phase = if (cbr >= total) out_phase else in_phase;
    var levels: [4]u16 = undefined;
    var sum: u32 = 0;
    for (&levels) |*l| {
        const v = std.math.clamp(o, 0, peak);
        // Gamma 1.8, as the reference's `v * LED_GAMMA`.
        l.* = @intCast(@divTrunc(v * 9, 5));
        sum += l.*;
        o -= phase;
    }
    if (cbr > 0 and sum == 0) return .done;
    return .{ .levels = levels };
}

fn first_done() u32 {
    var n: u32 = 0;
    while (frame(n) != .done) n += 1;
    return n;
}

test "dark for the first 200 ms, then the first LED rises alone" {
    try std.testing.expectEqual(Frame{ .levels = .{ 0, 0, 0, 0 } }, frame(0));
    try std.testing.expectEqual(Frame{ .levels = .{ 0, 0, 0, 0 } }, frame(40));
    try std.testing.expectEqual(Frame{ .levels = .{ 1, 0, 0, 0 } }, frame(41));
    try std.testing.expectEqual(Frame{ .levels = .{ 63, 9, 0, 0 } }, frame(75));
}

test "all four at peak, then a shared fade to done in about 1.6 s" {
    try std.testing.expectEqual(Frame{ .levels = .{ 270, 270, 270, 270 } }, frame(40 + 240));
    const n = first_done();
    try std.testing.expect(n * frame_ms > 1_500 and n * frame_ms < 1_800);
    try std.testing.expect(frame(n - 1) != .done);
}

test "levels stay within the PWM wrap" {
    var n: u32 = 0;
    while (n < 400) : (n += 1) switch (frame(n)) {
        .levels => |ls| for (ls) |l| try std.testing.expect(l <= wrap),
        .done => {},
    };
}
