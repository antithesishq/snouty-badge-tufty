/// HOME button press classification (pure, host-tested).
///
/// A press shorter than `long_press_us` is reported on release as
/// `short_press`. Holding for `long_press_us` reports `long_press` once,
/// while still held (the caller reboots), and the eventual release is then
/// swallowed.
const std = @import("std");

pub const long_press_us: u64 = 1_000_000;

pub const Event = enum { none, short_press, long_press };

pub const HomeButton = struct {
    down_since: ?u64 = null,
    long_fired: bool = false,

    pub fn update(h: *HomeButton, held: bool, now_us: u64) Event {
        if (held) {
            const since = h.down_since orelse blk: {
                h.down_since = now_us;
                h.long_fired = false;
                break :blk now_us;
            };
            if (!h.long_fired and now_us - since >= long_press_us) {
                h.long_fired = true;
                return .long_press;
            }
            return .none;
        }
        if (h.down_since == null) return .none;
        h.down_since = null;
        return if (h.long_fired) .none else .short_press;
    }
};

test "short press reports on release" {
    var h: HomeButton = .{};
    try std.testing.expectEqual(Event.none, h.update(true, 0));
    try std.testing.expectEqual(Event.none, h.update(true, 500_000));
    try std.testing.expectEqual(Event.short_press, h.update(false, 600_000));
    try std.testing.expectEqual(Event.none, h.update(false, 700_000));
}

test "long press fires once while held" {
    var h: HomeButton = .{};
    _ = h.update(true, 10);
    try std.testing.expectEqual(Event.none, h.update(true, 999_999));
    try std.testing.expectEqual(Event.long_press, h.update(true, 1_000_010));
    try std.testing.expectEqual(Event.none, h.update(true, 2_000_000));
    try std.testing.expectEqual(Event.none, h.update(false, 2_100_000));
}
