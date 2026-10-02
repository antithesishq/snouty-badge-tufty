/// Tufty buttons -> SYCL cart Controls (pure, host-tested).
///
/// The Tufty has five play buttons (A, B, C under the screen, UP and DOWN
/// on the right edge) plus HOME, which the OS keeps for itself. The SYCL
/// badge has a joystick (up/down/left/right/click), A, B, START and SELECT.
/// A per-cart `Map` is pure data built from the primitives in
/// docs/ports/README.md:
///
///   direct   `held` bits are set while the trigger is held.
///   chord    a trigger of 2+ buttons. While it is held its bits are set and
///            the members' own bindings are masked until each member is
///            released. `chord_ms` (per map) delays the `held` bits of
///            chord members so a chord can form without leaking; a member
///            tapped and released inside that delay still sends its bits as
///            a pulse.
///   tap      `tap` bits pulse when the trigger is released within `tap_ms`.
///   hold     `hold` bits are set once the trigger has been held `hold_ms`,
///            until release.
///   pulses   every rising output bit stays set for at least 2 cart
///            presents, so a cart that samples once per update (e.g.
///            snouty-reflections at 20 fps) always sees it.
const std = @import("std");

/// Bit positions of the SYCL `Controls` packed struct (os_abi / api.zig):
/// start, select, a, b, click, up, down, left, right.
pub const Control = enum(u4) { start = 0, select, a, b, click, up, down, left, right };

pub fn bit(c: Control) u16 {
    return @as(u16, 1) << @intFromEnum(c);
}

/// Tufty play buttons, same bit order as drivers/buttons.zig State.
pub const Button = enum(u3) { a = 0, b, c, up, down };
pub const button_count = 5;

pub fn btn(b: Button) u8 {
    return @as(u8, 1) << @intFromEnum(b);
}

pub const Binding = struct {
    /// Trigger: one button bit (direct) or several (chord).
    on: u8,
    /// Controls bits while held (delayed by chord_ms for chord members).
    held: u16 = 0,
    /// Controls bits pulsed on a release within tap_ms.
    tap: u16 = 0,
    /// Controls bits from hold_ms of holding until release.
    hold: u16 = 0,
    tap_ms: u16 = 300,
    hold_ms: u16 = 500,

    fn is_chord(b: Binding) bool {
        return @popCount(b.on) > 1;
    }
};

pub const Map = struct {
    bindings: []const Binding,
    /// Delay before a chord member's direct `held` bits start (0 = at once).
    chord_ms: u16 = 0,
    /// Minimum length of any rising output bit, in cart presents.
    min_presents: u8 = 2,

    fn chord_members(map: *const Map) u8 {
        var m: u8 = 0;
        for (map.bindings) |b| {
            if (b.is_chord()) m |= b.on;
        }
        return m;
    }
};

pub const max_bindings = 16;

/// Runtime state of one map. Feed it the held buttons every OS loop.
pub const Mapper = struct {
    map: *const Map,
    prev_held: u8 = 0,
    pressed_at: [button_count]u64 = @splat(0),
    /// A member of a chord that formed: its own bindings stay masked until it is released.
    consumed: u8 = 0,
    active: [max_bindings]bool = @splat(false),
    active_since: [max_bindings]u64 = @splat(0),
    /// Pulse stretch per output bit: asserted while presents < until.
    until: [16]u32 = @splat(0),
    prev_out: u16 = 0,

    pub fn init(map: *const Map) Mapper {
        std.debug.assert(map.bindings.len <= max_bindings);
        return .{ .map = map };
    }

    /// `held`: Tufty button bits (btn()); `now_us`: time; `presents`: number
    /// of cart presents so far. Returns the Controls bits for the cart.
    pub fn update(m: *Mapper, held: u8, now_us: u64, presents: u32) u16 {
        const map = m.map;
        const members = map.chord_members();
        const chord_us: u64 = @as(u64, map.chord_ms) * 1000;

        const pressed = held & ~m.prev_held;
        const released = m.prev_held & ~held;
        for (0..button_count) |i| {
            const b: u8 = @as(u8, 1) << @intCast(i);
            if (pressed & b != 0) m.pressed_at[i] = now_us;
        }
        m.consumed &= ~released;

        // Chords claim their members first.
        for (map.bindings) |bd| {
            if (bd.is_chord() and held & bd.on == bd.on) m.consumed |= bd.on;
        }

        var level: u16 = 0;
        var pulse: u16 = 0;
        for (map.bindings, 0..) |bd, i| {
            const satisfied = if (bd.is_chord())
                held & bd.on == bd.on
            else
                held & bd.on != 0 and m.consumed & bd.on == 0;

            if (satisfied) {
                if (!m.active[i]) {
                    m.active[i] = true;
                    m.active_since[i] = now_us;
                }
                const dur = now_us - m.active_since[i];
                const delayed = !bd.is_chord() and members & bd.on != 0 and dur < chord_us;
                if (!delayed) level |= bd.held;
                if (bd.hold != 0 and dur >= @as(u64, bd.hold_ms) * 1000) level |= bd.hold;
            } else if (m.active[i]) {
                m.active[i] = false;
                const dur = now_us - m.active_since[i];
                // Deactivated by a release (not by a chord masking it).
                const by_release = held & bd.on != bd.on;
                if (by_release) {
                    if (dur <= @as(u64, bd.tap_ms) * 1000) pulse |= bd.tap;
                    // A chord member tapped inside the chord delay never sent
                    // its held bits: send them now as a pulse.
                    if (!bd.is_chord() and members & bd.on != 0 and dur < chord_us) pulse |= bd.held;
                }
            }
        }

        // Stretch every rising bit (level edge or pulse) over min_presents.
        const rising = (level & ~m.prev_out) | pulse;
        for (0..16) |bi| {
            if (rising & (@as(u16, 1) << @intCast(bi)) != 0) m.until[bi] = presents + map.min_presents;
        }
        var out = level;
        for (0..16) |bi| {
            if (presents < m.until[bi]) out |= @as(u16, 1) << @intCast(bi);
        }

        m.prev_held = held;
        m.prev_out = out;
        return out;
    }
};

// ========================================
// Maps
// ========================================

/// The split d-pad (docs/ports/README.md): A/B = left/right under the left
/// thumb, UP/DOWN = up/down, C = the cart's A. The two chords that never
/// collide with play: A+B = the cart's B, UP+DOWN = START.
pub const default: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .held = bit(.a) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.b) },
        .{ .on = btn(.up) | btn(.down), .held = bit(.start) },
    },
};

/// snouty-run reads only A (jump, on the press edge). Split d-pad: C jumps.
/// A/B/UP/DOWN pass through as left/right/up/down (the cart ignores them).
/// No chords, so nothing is ever delayed or masked.
pub const snouty_run: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .held = bit(.a) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
    },
};

/// demosnout (docs/ports/demosnout.md) reads only press edges: in the show
/// Select opens the picker, A/Start skips, B toggles hold; in the picker
/// Up/Down move, A jumps, B/Select close. The Tufty labels match the cart's
/// A and B, C is Select. Start (a duplicate of A) and Left/Right/click are
/// never sent, so the cart's Start+Select ignore-everything branch can never
/// trigger. No chords.
pub const demosnout: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.a) },
        .{ .on = btn(.b), .held = bit(.b) },
        .{ .on = btn(.c), .held = bit(.select) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
    },
};

/// The map for a cart, by its -Dcart name.
pub fn for_cart(comptime name: []const u8) *const Map {
    if (std.mem.eql(u8, name, "snouty-run")) return &snouty_run;
    if (std.mem.eql(u8, name, "demosnout")) return &demosnout;
    return &default;
}

// ========================================
// Tests
// ========================================

const testing = std.testing;
const ms = 1000;

/// Steps a mapper with one present per call (a 60 fps-ish cart).
const Sim = struct {
    m: Mapper,
    t: u64 = 0,
    presents: u32 = 0,

    fn step(s: *Sim, held: u8, dt_ms: u64) u16 {
        s.t += dt_ms * ms;
        s.presents += 1;
        return s.m.update(held, s.t, s.presents);
    }
};

test "direct bits follow the buttons" {
    var s: Sim = .{ .m = .init(&snouty_run) };
    try testing.expectEqual(bit(.a), s.step(btn(.c), 16));
    try testing.expectEqual(bit(.a), s.step(btn(.c), 16));
    try testing.expectEqual(bit(.a) | bit(.up), s.step(btn(.c) | btn(.up), 16));
    // Released: A rose long ago and drops at once; UP rose one present ago
    // and is stretched to 2 presents.
    try testing.expectEqual(bit(.up), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "a one-frame press lasts 2 presents" {
    var s: Sim = .{ .m = .init(&snouty_run) };
    _ = s.step(0, 16);
    // Pressed and released between two presents of a slow cart: the OS sees
    // it for one loop, then the bit is held over the following presents.
    s.t += 5 * ms;
    try testing.expectEqual(bit(.a), s.m.update(btn(.c), s.t, s.presents));
    s.t += 5 * ms;
    try testing.expectEqual(bit(.a), s.m.update(0, s.t, s.presents));
    try testing.expectEqual(bit(.a), s.step(0, 50));
    try testing.expectEqual(@as(u16, 0), s.step(0, 50));
}

test "default: chords mask their members" {
    var s: Sim = .{ .m = .init(&default) };
    try testing.expectEqual(bit(.left), s.step(btn(.a), 16));
    _ = s.step(btn(.a), 16);
    _ = s.step(btn(.a), 16);
    // B joins: the chord takes over; left's stretch has long expired.
    try testing.expectEqual(bit(.b), s.step(btn(.a) | btn(.b), 16));
    _ = s.step(btn(.a) | btn(.b), 16);
    try testing.expectEqual(bit(.b), s.step(btn(.a) | btn(.b), 16));
    // Releasing B: A stays masked until it too is released.
    _ = s.step(btn(.a), 16);
    _ = s.step(btn(.a), 16);
    try testing.expectEqual(@as(u16, 0), s.step(btn(.a), 16));
    _ = s.step(0, 16);
    try testing.expectEqual(bit(.left), s.step(btn(.a), 16));
    // C is never part of a chord.
    _ = s.step(0, 16);
    _ = s.step(0, 16);
    _ = s.step(0, 16);
    try testing.expectEqual(bit(.a) | bit(.start), s.step(btn(.c) | btn(.up) | btn(.down), 16));
}

const delayed_map: Map = .{
    .chord_ms = 60,
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.select) },
    },
};

test "chord_ms delays members and forms chords without leaks" {
    var s: Sim = .{ .m = .init(&delayed_map) };
    try testing.expectEqual(@as(u16, 0), s.step(btn(.a), 20));
    try testing.expectEqual(@as(u16, 0), s.step(btn(.a), 20));
    try testing.expectEqual(bit(.select), s.step(btn(.a) | btn(.b), 20));
    // Held A alone past chord_ms: left.
    var t: Sim = .{ .m = .init(&delayed_map) };
    try testing.expectEqual(@as(u16, 0), t.step(btn(.a), 20));
    try testing.expectEqual(@as(u16, 0), t.step(btn(.a), 20));
    try testing.expectEqual(@as(u16, 0), t.step(btn(.a), 20));
    try testing.expectEqual(bit(.left), t.step(btn(.a), 20));
}

test "chord member tapped inside chord_ms still sends a pulse" {
    var s: Sim = .{ .m = .init(&delayed_map) };
    try testing.expectEqual(@as(u16, 0), s.step(btn(.a), 20));
    try testing.expectEqual(bit(.left), s.step(0, 20));
    try testing.expectEqual(bit(.left), s.step(0, 20));
    try testing.expectEqual(@as(u16, 0), s.step(0, 20));
}

const tap_hold_map: Map = .{
    .bindings = &.{
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.up) | btn(.down), .tap = bit(.select), .hold = bit(.start), .tap_ms = 300, .hold_ms = 500 },
    },
};

test "tap and hold on a chord" {
    // Tap: 100 ms, select pulses on release, never start.
    var s: Sim = .{ .m = .init(&tap_hold_map) };
    try testing.expectEqual(@as(u16, 0), s.step(btn(.up) | btn(.down), 16));
    for (0..5) |_| try testing.expectEqual(@as(u16, 0), s.step(btn(.up) | btn(.down), 16));
    try testing.expectEqual(bit(.select), s.step(0, 16));
    try testing.expectEqual(bit(.select), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));

    // Hold: start from 500 ms until release, no select.
    var h: Sim = .{ .m = .init(&tap_hold_map) };
    var out: u16 = 0;
    for (0..40) |_| out = h.step(btn(.up) | btn(.down), 16);
    try testing.expectEqual(bit(.start), out);
    // Release after a hold: start drops (its rise was long ago), no tap pulse.
    try testing.expectEqual(@as(u16, 0), h.step(0, 16));
}

test "demosnout: one control per button, 1:1" {
    try testing.expectEqual(&demosnout, for_cart("demosnout"));
    const cases = [_]struct { Button, u16 }{
        .{ .a, bit(.a) },
        .{ .b, bit(.b) },
        .{ .c, bit(.select) },
        .{ .up, bit(.up) },
        .{ .down, bit(.down) },
    };
    for (cases) |c| {
        var s: Sim = .{ .m = .init(&demosnout) };
        // No chord delay: the bit is there on the press itself.
        try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        try testing.expectEqual(@as(u16, 0), s.step(0, 16));
    }
}

test "demosnout: never start, never the exit chord, nothing masked" {
    // Every combination of the five buttons, held for a while: the output is
    // exactly the union of the direct bits (no chord masks anything), never
    // contains start, left, right or click, so start+select never forms.
    const forbidden = bit(.start) | bit(.left) | bit(.right) | bit(.click);
    for (0..32) |combo_usize| {
        const combo: u8 = @intCast(combo_usize);
        var expect: u16 = 0;
        if (combo & btn(.a) != 0) expect |= bit(.a);
        if (combo & btn(.b) != 0) expect |= bit(.b);
        if (combo & btn(.c) != 0) expect |= bit(.select);
        if (combo & btn(.up) != 0) expect |= bit(.up);
        if (combo & btn(.down) != 0) expect |= bit(.down);
        var s: Sim = .{ .m = .init(&demosnout) };
        var out: u16 = 0;
        for (0..10) |_| {
            out = s.step(combo, 16);
            try testing.expectEqual(@as(u16, 0), out & forbidden);
        }
        try testing.expectEqual(expect, out);
    }
}

test "demosnout: a quick tap of C still opens the picker" {
    // The cart reads press edges once per update; a tap shorter than one
    // present is stretched over 2 presents, so update() sees the edge.
    var s: Sim = .{ .m = .init(&demosnout) };
    _ = s.step(0, 16);
    s.t += 3 * ms;
    try testing.expectEqual(bit(.select), s.m.update(btn(.c), s.t, s.presents));
    s.t += 3 * ms;
    try testing.expectEqual(bit(.select), s.m.update(0, s.t, s.presents));
    try testing.expectEqual(bit(.select), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "control bits match the SYCL Controls layout" {
    // api.zig: packed struct(u16) { start, select, a, b, click, up, down, left, right, _pad: u7 }
    try testing.expectEqual(@as(u16, 0x0001), bit(.start));
    try testing.expectEqual(@as(u16, 0x0004), bit(.a));
    try testing.expectEqual(@as(u16, 0x0100), bit(.right));
}
