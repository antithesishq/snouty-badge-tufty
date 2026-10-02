/// Arcade session logic (pure, host-tested): which screen is up, the menu
/// cursor, what HOME does, and which buttons the cart may see.
///
/// cart_host.zig feeds `update` the buttons every OS loop and executes the
/// `Command` it returns. All of the hardware work (stopping core 1, the
/// panel) stays there; everything that decides *when* lives here.
///
///   menu  UP/DOWN move the cursor (wrapping, auto-repeat while held),
///         A or C launches the highlighted cart, HOME short does nothing.
///   cart  HOME short: arcade -> back to the menu with this cart
///         highlighted; single-cart build -> restart the cart.
///   any   HOME held 1 s: BOOTSEL.
///
/// A button that is down when a cart launches (the A or C that launched it)
/// is masked from the cart until it is released, so the cart never starts
/// with a press already in flight. Buttons down when the menu comes back
/// likewise never count as menu presses until released.
const std = @import("std");
const home_logic = @import("home.zig");

/// Play button bits, same order as drivers/buttons.zig State and
/// controls_map.Button.
pub const btn_a: u8 = 1 << 0;
pub const btn_b: u8 = 1 << 1;
pub const btn_c: u8 = 1 << 2;
pub const btn_up: u8 = 1 << 3;
pub const btn_down: u8 = 1 << 4;
pub const play_mask: u8 = 0x1F;

pub const max_carts = 32;

/// First auto-repeat after this long, then one step every repeat_us.
pub const repeat_delay_us: u64 = 400_000;
pub const repeat_us: u64 = 150_000;

pub const Screen = union(enum) {
    menu,
    cart: u8,
};

pub const Command = union(enum) {
    none,
    /// The menu cursor moved: redraw the menu.
    redraw,
    /// Stop the running cart, then draw the menu.
    stop_to_menu,
    /// Stop whatever runs (if anything), then start cart i from a fresh image.
    launch: u8,
    /// Reboot into the bootrom's USB mode.
    bootsel,
};

pub const Session = struct {
    count: u8,
    arcade: bool,
    /// Bit i set: cart i has a valid image and may launch.
    playable: u32,
    screen: Screen,
    cursor: u8 = 0,
    /// The cart launched last (the menu comes back highlighting it).
    last: ?u8 = null,
    home: home_logic.HomeButton = .{},
    /// Buttons held at the last screen change, ignored until released.
    stale: u8 = 0,
    prev: u8 = 0,
    /// UP/DOWN auto-repeat: when the held direction moves next.
    repeat_at: u64 = 0,

    pub fn init(count: u8, arcade: bool, playable: u32) Session {
        std.debug.assert(count >= 1 and count <= max_carts);
        return .{
            .count = count,
            .arcade = arcade,
            .playable = playable,
            .screen = if (arcade) .menu else .{ .cart = 0 },
        };
    }

    /// The command that brings the first screen up: the menu, or the cart.
    pub fn boot(s: *Session, held: u8) Command {
        s.stale = held & play_mask;
        s.prev = held & play_mask;
        if (s.arcade) return .redraw;
        s.last = 0;
        return .{ .launch = 0 };
    }

    pub fn is_playable(s: *const Session, i: u8) bool {
        return i < s.count and s.playable & (@as(u32, 1) << @intCast(i)) != 0;
    }

    /// One OS loop. `held`: play button bits (btn_*), `home`: HOME held.
    pub fn update(s: *Session, held_in: u8, home: bool, now_us: u64) Command {
        const held = held_in & play_mask;
        s.stale &= held;
        defer s.prev = held;

        switch (s.home.update(home, now_us)) {
            .long_press => return .bootsel,
            .short_press => switch (s.screen) {
                .menu => {},
                .cart => |i| {
                    s.stale = held;
                    if (!s.arcade) return .{ .launch = i };
                    s.screen = .menu;
                    s.cursor = i;
                    return .stop_to_menu;
                },
            },
            .none => {},
        }

        if (s.screen == .cart) return .none;
        // While HOME is down nothing else happens in the menu.
        if (s.home.down_since != null) return .none;

        const live = held & ~s.stale;
        const pressed = live & ~s.prev;

        if (pressed & (btn_a | btn_c) != 0 and s.is_playable(s.cursor)) {
            s.screen = .{ .cart = s.cursor };
            s.last = s.cursor;
            s.stale = held;
            return .{ .launch = s.cursor };
        }

        // UP/DOWN: one step on the press, then auto-repeat while held. Both
        // held: neither moves.
        const dir = live & (btn_up | btn_down);
        if (dir == btn_up or dir == btn_down) {
            const step_now = if (pressed & dir != 0) blk: {
                s.repeat_at = now_us + repeat_delay_us;
                break :blk true;
            } else if (now_us >= s.repeat_at) blk: {
                s.repeat_at = now_us + repeat_us;
                break :blk true;
            } else false;
            if (step_now) {
                s.cursor = if (dir == btn_up)
                    (if (s.cursor == 0) s.count - 1 else s.cursor - 1)
                else
                    (if (s.cursor + 1 == s.count) 0 else s.cursor + 1);
                return .redraw;
            }
        }
        return .none;
    }

    /// The play buttons the running cart may see: `held` minus those still
    /// down from the launch.
    pub fn cart_buttons(s: *Session, held: u8) u8 {
        s.stale &= held;
        return held & play_mask & ~s.stale;
    }
};

// ========================================
// Tests
// ========================================

const testing = std.testing;
const ms: u64 = 1000;

/// Drives a session like cart_host does, and models the hardware the
/// commands act on: whether core 1 runs, which image it was started from,
/// and the invariants of a stop (nothing launches over a running cart
/// without stopping it first; the menu is only drawn with core 1 stopped).
const Rig = struct {
    s: Session,
    t: u64 = 0,
    running: ?u8 = null,
    launches: u32 = 0,
    stops: u32 = 0,
    menu_draws: u32 = 0,
    bootsel: bool = false,

    fn init(count: u8, arcade: bool, playable: u32) Rig {
        var r: Rig = .{ .s = .init(count, arcade, playable) };
        r.exec(r.s.boot(0));
        return r;
    }

    fn exec(r: *Rig, cmd: Command) void {
        switch (cmd) {
            .none => {},
            .redraw => {
                std.debug.assert(r.running == null);
                r.menu_draws += 1;
            },
            .stop_to_menu => {
                r.stop();
                r.menu_draws += 1;
            },
            .launch => |i| {
                r.stop();
                std.debug.assert(r.s.is_playable(i));
                r.running = i;
                r.launches += 1;
            },
            .bootsel => r.bootsel = true,
        }
    }

    fn stop(r: *Rig) void {
        if (r.running != null) r.stops += 1;
        r.running = null;
    }

    /// Holds `held` (+HOME) for `dt` ms in 2 ms loops.
    fn hold(r: *Rig, held: u8, home: bool, dt: u64) void {
        var left = dt;
        while (left > 0) : (left -= @min(left, 2)) {
            r.t += 2 * ms;
            r.exec(r.s.update(held, home, r.t));
        }
    }

    fn tap(r: *Rig, b: u8) void {
        r.hold(b, false, 40);
        r.hold(0, false, 40);
    }

    fn home_tap(r: *Rig) void {
        r.hold(0, true, 100);
        r.hold(0, false, 20);
    }
};

test "arcade boots into the menu with nothing running" {
    const r: Rig = .init(2, true, 0b11);
    try testing.expectEqual(Screen.menu, r.s.screen);
    try testing.expectEqual(@as(?u8, null), r.running);
    try testing.expectEqual(@as(u32, 1), r.menu_draws);
}

test "single-cart build boots the cart and HOME restarts it" {
    var r: Rig = .init(1, false, 0b1);
    try testing.expectEqual(@as(?u8, 0), r.running);
    r.home_tap();
    try testing.expectEqual(@as(?u8, 0), r.running);
    try testing.expectEqual(@as(u32, 2), r.launches);
    try testing.expectEqual(@as(u32, 1), r.stops);
    try testing.expectEqual(@as(u32, 0), r.menu_draws);
    try testing.expectEqual(Screen{ .cart = 0 }, r.s.screen);
}

test "up/down wrap and redraw" {
    var r: Rig = .init(3, true, 0b111);
    r.tap(btn_up);
    try testing.expectEqual(@as(u8, 2), r.s.cursor);
    r.tap(btn_down);
    r.tap(btn_down);
    try testing.expectEqual(@as(u8, 1), r.s.cursor);
    try testing.expectEqual(@as(u32, 4), r.menu_draws);
    // Both at once: no move.
    r.hold(btn_up | btn_down, false, 40);
    try testing.expectEqual(@as(u8, 1), r.s.cursor);
}

test "holding DOWN auto-repeats" {
    var r: Rig = .init(8, true, 0xFF);
    r.hold(btn_down, false, 400 + 3 * 150 + 10);
    // The press, then at 400, 550, 700, 850 ms.
    try testing.expectEqual(@as(u8, 5), r.s.cursor);
}

test "launch, HOME back, relaunch another, repeatedly" {
    var r: Rig = .init(3, true, 0b111);
    var expect_launches: u32 = 0;
    for (0..20) |round| {
        const want: u8 = @intCast(round % 3);
        // Walk the cursor to `want` from wherever it is.
        while (r.s.cursor != want) r.tap(btn_down);
        r.tap(if (round % 2 == 0) btn_c else btn_a);
        expect_launches += 1;
        try testing.expectEqual(@as(?u8, want), r.running);
        try testing.expectEqual(Screen{ .cart = want }, r.s.screen);
        try testing.expectEqual(@as(?u8, want), r.s.last);
        // Play a bit: buttons go to the cart, not the menu.
        r.tap(btn_down);
        r.tap(btn_c);
        try testing.expectEqual(@as(?u8, want), r.running);
        // HOME: back to the menu, this cart highlighted, core 1 stopped.
        r.home_tap();
        try testing.expectEqual(Screen.menu, r.s.screen);
        try testing.expectEqual(@as(?u8, null), r.running);
        try testing.expectEqual(want, r.s.cursor);
    }
    try testing.expectEqual(expect_launches, r.launches);
    try testing.expectEqual(expect_launches, r.stops);
}

test "HOME held 1 s is BOOTSEL in the menu and in a cart, never a menu return" {
    var r: Rig = .init(2, true, 0b11);
    r.hold(0, true, 1100);
    try testing.expect(r.bootsel);

    var c: Rig = .init(2, true, 0b11);
    c.tap(btn_c);
    c.hold(0, true, 999);
    try testing.expect(!c.bootsel);
    c.hold(0, true, 10);
    try testing.expect(c.bootsel);
    // The release after a long press is swallowed.
    c.hold(0, false, 20);
    try testing.expectEqual(@as(?u8, 0), c.running);
}

test "the launching button is masked from the cart until released" {
    var r: Rig = .init(2, true, 0b11);
    r.hold(btn_c, false, 10); // launches on the press
    try testing.expectEqual(@as(?u8, 0), r.running);
    try testing.expectEqual(@as(u8, 0), r.s.cart_buttons(btn_c));
    try testing.expectEqual(btn_up, r.s.cart_buttons(btn_c | btn_up));
    try testing.expectEqual(@as(u8, 0), r.s.cart_buttons(0));
    // Released once: C is the cart's again.
    try testing.expectEqual(btn_c, r.s.cart_buttons(btn_c));
}

test "buttons held through a HOME return are not menu presses" {
    var r: Rig = .init(3, true, 0b111);
    r.tap(btn_c);
    try testing.expectEqual(@as(?u8, 0), r.running);
    // Holding DOWN and C in the cart while tapping HOME.
    r.hold(btn_down | btn_c, true, 100);
    r.hold(btn_down | btn_c, false, 600);
    try testing.expectEqual(Screen.menu, r.s.screen);
    try testing.expectEqual(@as(u8, 0), r.s.cursor);
    try testing.expectEqual(@as(?u8, null), r.running);
    r.hold(0, false, 20);
    r.tap(btn_down);
    try testing.expectEqual(@as(u8, 1), r.s.cursor);
}

test "a cart with a bad image never launches" {
    var r: Rig = .init(2, true, 0b10);
    r.tap(btn_c);
    try testing.expectEqual(@as(?u8, null), r.running);
    r.tap(btn_down);
    r.tap(btn_c);
    try testing.expectEqual(@as(?u8, 1), r.running);
}

test "menu ignores buttons while HOME is down" {
    var r: Rig = .init(2, true, 0b11);
    r.hold(0, true, 50);
    r.hold(btn_c, true, 50);
    try testing.expectEqual(@as(?u8, null), r.running);
    r.hold(0, false, 20);
    try testing.expectEqual(Screen.menu, r.s.screen);
}
