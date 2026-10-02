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
///            released. `chord_ms` (per map, or per binding to override it)
///            delays the `held` bits of chord members so a chord can form
///            without leaking; a member tapped and released inside that
///            delay still sends its bits as a pulse.
///   tap      `tap` bits pulse when the trigger is released within `tap_ms`.
///   hold     `hold` bits are set once the trigger has been held `hold_ms`,
///            until release.
///   pulses   every rising output bit stays set for at least 2 cart
///            presents, so a cart that samples once per update (e.g.
///            snouty-reflections at 20 fps) always sees it.
///   latch    `latch` bits are latched on (kept set with nothing held) by
///            `latch_by`: `.double_tap` = a tap (released within `tap_ms`),
///            then a new press within `double_ms` of that release;
///            `.press` = any press. `unlatch` bits are cleared when a
///            binding becomes active (a press, or a chord forming); that
///            press is spent and never starts a double tap. A binding with
///            both (snoutenstein's UP) toggles: double tap on, touch off.
///            `retrigger`: a press while the bits are already latched drops
///            them for `min_presents` presents and raises them again, so the
///            cart sees a fresh press edge without the bits going off for
///            good (snouty-bugs' C: press = autofire on, later presses
///            re-press A). Nothing is ever latched at boot, and a fresh
///            mapper (a HOME restart) clears every latch.
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
    /// Controls bits this binding latches on (kept set with nothing held),
    /// when `latch_by` says so.
    latch: u16 = 0,
    /// What latches `latch`: a double tap (see `double_ms`), or any press.
    latch_by: LatchBy = .double_tap,
    /// A press while `latch` is already latched re-triggers it: the bits
    /// drop for min_presents presents and rise again (a fresh press edge).
    retrigger: bool = false,
    /// Latched bits this binding clears when it becomes active.
    unlatch: u16 = 0,
    tap_ms: u16 = 300,
    hold_ms: u16 = 500,
    /// A tap, then a press within this (release to press), latches `latch`
    /// (latch_by = .double_tap).
    double_ms: u16 = 250,
    /// This direct binding's chord delay, overriding the map's `chord_ms`
    /// (null: the map's). Lets a map delay only the members whose leak would
    /// matter (snouty-zero: UP is Overclock) and keep the others instant.
    chord_ms: ?u16 = null,

    fn is_chord(b: Binding) bool {
        return @popCount(b.on) > 1;
    }
};

/// What switches a binding's `latch` bits on.
pub const LatchBy = enum {
    /// A tap (released within tap_ms), then a press within double_ms.
    double_tap,
    /// Any press (the binding becoming active).
    press,
};

pub const Map = struct {
    bindings: []const Binding,
    /// Delay before a chord member's direct `held` bits start (0 = at once).
    /// A binding's own `chord_ms` overrides it for that binding.
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
    /// Latched bits, on until an `unlatch` binding fires (or init).
    latched: u16 = 0,
    /// Re-trigger gaps: a latched bit is forced low while presents < gap_until.
    gap_until: [16]u32 = @splat(0),
    /// When each binding's last tap ended, if that tap may start a double
    /// tap (null after a long press, or after a spent press).
    tap_end: [max_bindings]?u64 = @splat(null),
    /// This activation of the binding changed the latch, so it is spent.
    spent: [max_bindings]bool = @splat(false),

    pub fn init(map: *const Map) Mapper {
        std.debug.assert(map.bindings.len <= max_bindings);
        return .{ .map = map };
    }

    /// `held`: Tufty button bits (btn()); `now_us`: time; `presents`: number
    /// of cart presents so far. Returns the Controls bits for the cart.
    pub fn update(m: *Mapper, held: u8, now_us: u64, presents: u32) u16 {
        const map = m.map;
        const members = map.chord_members();

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
            const chord_us: u64 = @as(u64, bd.chord_ms orelse map.chord_ms) * 1000;
            const satisfied = if (bd.is_chord())
                held & bd.on == bd.on
            else
                held & bd.on != 0 and m.consumed & bd.on == 0;

            if (satisfied) {
                if (!m.active[i]) {
                    m.active[i] = true;
                    m.active_since[i] = now_us;
                    m.activate_latch(i, bd, now_us, presents + map.min_presents);
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
                    const tapped = dur <= @as(u64, bd.tap_ms) * 1000;
                    if (tapped) pulse |= bd.tap;
                    m.tap_end[i] = if (tapped and !m.spent[i]) now_us else null;
                    // A chord member tapped inside the chord delay never sent
                    // its held bits: send them now as a pulse.
                    if (!bd.is_chord() and members & bd.on != 0 and dur < chord_us) pulse |= bd.held;
                }
            }
        }

        // Latched bits, minus any in a re-trigger gap.
        var gap: u16 = 0;
        for (0..16) |bi| {
            if (presents < m.gap_until[bi]) gap |= @as(u16, 1) << @intCast(bi);
        }
        level = (level | m.latched) & ~gap;

        // Stretch every rising bit (level edge or pulse) over min_presents.
        const rising = (level & ~m.prev_out) | pulse;
        for (0..16) |bi| {
            if (rising & (@as(u16, 1) << @intCast(bi)) != 0) m.until[bi] = presents + map.min_presents;
        }
        var out = level;
        for (0..16) |bi| {
            if (presents < m.until[bi]) out |= @as(u16, 1) << @intCast(bi);
        }
        // A gap beats a stretch, so a re-trigger is always a real edge.
        out &= ~gap;

        m.prev_held = held;
        m.prev_out = out;
        return out;
    }

    /// Binding `i` just became active. In order: an unlatch press clears
    /// its bits (and is spent); a `retrigger` press of bits already latched
    /// gaps them until `gap_end` (the next presents count they may rise
    /// at); otherwise a press that meets `latch_by` latches (spent too, so
    /// a third tap does not start another double tap).
    fn activate_latch(m: *Mapper, i: usize, bd: Binding, now_us: u64, gap_end: u32) void {
        const tap_end = m.tap_end[i];
        m.tap_end[i] = null;
        m.spent[i] = false;
        if (bd.unlatch & m.latched != 0) {
            m.latched &= ~bd.unlatch;
            m.spent[i] = true;
        } else if (bd.latch == 0) {
            return;
        } else if (bd.retrigger and m.latched & bd.latch == bd.latch) {
            for (0..16) |bi| {
                if (bd.latch & (@as(u16, 1) << @intCast(bi)) != 0) m.gap_until[bi] = gap_end;
            }
            m.spent[i] = true;
        } else {
            const trigger = switch (bd.latch_by) {
                .press => true,
                .double_tap => if (tap_end) |t| now_us - t <= @as(u64, bd.double_ms) * 1000 else false,
            };
            if (trigger) {
                m.latched |= bd.latch;
                m.spent[i] = true;
            }
        }
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

/// snoutenstein (docs/ports/snoutenstein.md): tank controls, no strafe. The
/// left thumb turns on A/B; the right thumb has either C (fire, held) or
/// UP/DOWN (walk), not both, so a double tap of UP latches walking forward
/// (autowalk) and frees the right thumb for C: walk + turn + fire at once.
/// Touching UP or DOWN, or rewinding, drops the latch. A+B (turn both ways,
/// which cancels) is the cart's B: rewind, held. UP+DOWN tap = select
/// (weapon; sound on the title), hold = start (pause; test level on the
/// title). chord_ms 0: a leaked frame is one turn or walk tick.
pub const snoutenstein: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .held = bit(.a) },
        .{ .on = btn(.up), .held = bit(.up), .latch = bit(.up), .unlatch = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down), .unlatch = bit(.up) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.b), .unlatch = bit(.up) },
        .{ .on = btn(.up) | btn(.down), .tap = bit(.select), .hold = bit(.start), .tap_ms = 300, .hold_ms = 500 },
    },
};

/// snouty-reflections (app.zig handle_input, once per 20 fps update): held
/// left/right orbit, held up/down change the eye height, and the edges of
/// A (freeze), B (dither), SELECT (preset) and START (attract).
/// Split d-pad: A/B orbit, UP/DOWN height, C freezes at once (C is in no
/// chord, so it is never delayed). A+B = SELECT, UP+DOWN = B. A direction
/// press leaves attract for the free camera, so chord_ms = 60 keeps a
/// chord from leaking a direction first (about one 20 fps update of extra
/// latency). START is not mapped: free camera returns to attract after
/// 20 s, a converged freeze after 60 s, and a HOME tap restarts the cart.
pub const snouty_reflections: Map = .{
    .chord_ms = 60,
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.c), .held = bit(.a) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.select) },
        .{ .on = btn(.up) | btn(.down), .held = bit(.b) },
    },
};

/// snouty-maze (docs/ports/snouty-maze.md): the split d-pad. A/B pivot
/// left/right (edges), UP/DOWN step forward/back (edges, held repeats); any
/// of them takes the camera over from the autopilot. C carries the cart's
/// two screensaver buttons as tap/hold: a tap (released within 400 ms)
/// pulses A = skip to the finish sequence, a hold (600 ms) sets Start =
/// toggle the name strip, once per hold. No chords, so the direction
/// buttons are never delayed or masked. B, Select (a no-op LED flag in
/// release builds) and click are never sent.
pub const snouty_maze: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.c), .tap = bit(.a), .hold = bit(.start), .tap_ms = 400, .hold_ms = 600 },
    },
};

/// snouty-bugs (docs/ports/snouty-bugs.md). The zapper fires while the
/// cart's A is held and firing never costs anything, so C latches autofire
/// on: the first C also starts a normal game from the title, and any later
/// C re-presses A, which starts the next game after a game over. That frees
/// the right thumb for UP/DOWN, which it cannot work while holding C. The
/// left thumb rocks A/B for left/right. A+B = the cart's B (hold to rewind,
/// Hardcore on the title), UP+DOWN = Start (pause/resume). chord_ms = 0: a
/// one-frame leak of left/right or up/down before a chord cancels in the
/// cart.
pub const snouty_bugs: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .latch = bit(.a), .latch_by = .press, .retrigger = true },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.b) },
        .{ .on = btn(.up) | btn(.down), .held = bit(.start) },
    },
};

/// snouty-flyover (docs/ports/snouty-flyover.md), a 30 fps flight read in
/// camera.pilot(): held left/right bank, held up/down pitch, A held =
/// boost, and the edges of B (the district verb), SELECT (skip to the next
/// district) and START (autopilot on/off). Any direction, A or B takes
/// manual control. Split d-pad: A/B bank, UP climbs and DOWN dives (the
/// cart's down and up: its stick is a flight stick, the Tufty's arrows say
/// which way the flyer goes), C = the verb at once (in no chord). A+B (a
/// flat left thumb) = boost, held. UP+DOWN tap = skip, hold = autopilot
/// toggle. chord_ms = 60 (two 30 fps frames): a leaked direction would take
/// manual control, which would undo a hold that means "autopilot off" and
/// drop the autopilot a skip keeps.
pub const snouty_flyover: Map = .{
    .chord_ms = 60,
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.up), .held = bit(.down) },
        .{ .on = btn(.down), .held = bit(.up) },
        .{ .on = btn(.c), .held = bit(.b) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.a) },
        .{ .on = btn(.up) | btn(.down), .tap = bit(.select), .hold = bit(.start), .tap_ms = 300, .hold_ms = 500 },
    },
};

/// snouty-genesis (docs/ports/snouty-genesis.md): the cart turns SYCL
/// controls into a Genesis pad (cart input.zig, default layout): d-pad,
/// badge A = Genesis C, badge B = Genesis B, Start = Start, a Select tap =
/// Genesis A, Select held 500 ms = the emulator menu. Split d-pad: A/B =
/// left/right, UP/DOWN = up/down, C = badge A (Genesis C, jump). A+B =
/// badge B (Genesis B, also jump in Sonic): the left thumb's jump while the
/// right thumb holds DOWN (crouch + jump, Sonic 2's spin dash), and the
/// menu's "back / resume". UP+DOWN tap = Start (pause, title screens);
/// held 300 ms = Select, held until release, so the cart's own 500 ms hold
/// opens its menu (0.8 s in all; released in between = a Select tap =
/// Genesis A). chord_ms 0: a chord leaks its first member for 2 presents
/// (a one-frame step in play; in the cart menu A+B can scrub back 0.5 s
/// before it resumes).
pub const snouty_genesis: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .held = bit(.a) },
        .{ .on = btn(.up), .held = bit(.up) },
        .{ .on = btn(.down), .held = bit(.down) },
        .{ .on = btn(.a) | btn(.b), .held = bit(.b) },
        .{ .on = btn(.up) | btn(.down), .tap = bit(.start), .hold = bit(.select), .tap_ms = 250, .hold_ms = 300 },
    },
};

/// snouty-zero (docs/ports/snouty-zero.md), a 60 fps Mode 7 racer: held
/// left/right steer, A held = accelerate, Down = brake (tight turn with a
/// steer), the Up edge = Overclock, B held = rewind, Start = pause (title,
/// results and menus confirm with A or Start). A racer accelerates nearly
/// all the time, so C latches the throttle on (snouty-bugs' autofire latch):
/// the first C starts it, and every later C re-presses A, which the menus
/// read as confirm. That frees the right thumb for UP (Overclock) and DOWN
/// (brake) while the left thumb steers on A/B. A+B (a flat left thumb) =
/// rewind, held. UP+DOWN = Start (pause / resume). A/B keep no chord delay
/// (a 2-present steer leak before a rewind is harmless), but UP and DOWN
/// wait 60 ms: an UP leak before the pause chord would fire an Overclock
/// (a quarter of the thermal bar), and in a menu a leaked UP or DOWN would
/// move the cursor before Start confirms (unpausing onto RESTART).
pub const snouty_zero: Map = .{
    .bindings = &.{
        .{ .on = btn(.a), .held = bit(.left) },
        .{ .on = btn(.b), .held = bit(.right) },
        .{ .on = btn(.c), .latch = bit(.a), .latch_by = .press, .retrigger = true },
        .{ .on = btn(.up), .held = bit(.up), .chord_ms = 60 },
        .{ .on = btn(.down), .held = bit(.down), .chord_ms = 60 },
        .{ .on = btn(.a) | btn(.b), .held = bit(.b) },
        .{ .on = btn(.up) | btn(.down), .held = bit(.start) },
    },
};

/// The map for a cart, by its -Dcart name.
pub fn for_cart(comptime name: []const u8) *const Map {
    if (std.mem.eql(u8, name, "snouty-flyover")) return &snouty_flyover;
    if (std.mem.eql(u8, name, "snouty-bugs")) return &snouty_bugs;
    if (std.mem.eql(u8, name, "snouty-run")) return &snouty_run;
    if (std.mem.eql(u8, name, "demosnout")) return &demosnout;
    if (std.mem.eql(u8, name, "snoutenstein")) return &snoutenstein;
    if (std.mem.eql(u8, name, "snouty-reflections")) return &snouty_reflections;
    if (std.mem.eql(u8, name, "snouty-maze")) return &snouty_maze;
    if (std.mem.eql(u8, name, "snouty-genesis")) return &snouty_genesis;
    if (std.mem.eql(u8, name, "snouty-zero")) return &snouty_zero;
    return &default;
}

// ---- snouty-genesis (self-contained; the cart samples once per 30 Hz update) ----

/// Steps a mapper like the genesis cart: one present per 33 ms update, with
/// several OS loops in between.
const GenSim = struct {
    m: Mapper = .init(&snouty_genesis),
    t: u64 = 0,
    presents: u32 = 0,

    /// Holds `held` for `dur_ms`, one OS loop per ms, a present every 33 ms;
    /// returns the OR of everything the cart saw at its presents.
    fn hold(s: *GenSim, held: u8, dur_ms: u64) u16 {
        var seen: u16 = 0;
        var i: u64 = 0;
        while (i < dur_ms) : (i += 1) {
            s.t += 1000;
            const out = s.m.update(held, s.t, s.presents);
            if (s.t % 33_000 < 1000) {
                s.presents += 1;
                seen |= out;
            }
        }
        return seen;
    }

    /// What the cart sees at its next present with `held`.
    fn sample(s: *GenSim, held: u8) u16 {
        var out: u16 = 0;
        while (true) {
            s.t += 1000;
            out = s.m.update(held, s.t, s.presents);
            if (s.t % 33_000 < 1000) {
                s.presents += 1;
                return out;
            }
        }
    }
};

test "genesis: for_cart picks its map; one control per button" {
    try testing.expectEqual(&snouty_genesis, for_cart("snouty-genesis"));
    const cases = [_]struct { b: Button, c: Control }{
        .{ .b = .a, .c = .left },
        .{ .b = .b, .c = .right },
        .{ .b = .c, .c = .a },
        .{ .b = .up, .c = .up },
        .{ .b = .down, .c = .down },
    };
    for (cases) |cs| {
        var s: GenSim = .{};
        try testing.expectEqual(bit(cs.c), s.sample(btn(cs.b)));
        try testing.expectEqual(bit(cs.c), s.hold(btn(cs.b), 500));
    }
}

test "genesis: run and jump together, roll (direction + DOWN)" {
    var s: GenSim = .{};
    try testing.expectEqual(bit(.right) | bit(.a), s.sample(btn(.b) | btn(.c)));
    try testing.expectEqual(bit(.right) | bit(.a), s.hold(btn(.b) | btn(.c), 300));
    _ = s.hold(0, 100);
    try testing.expectEqual(bit(.right) | bit(.down), s.sample(btn(.b) | btn(.down)));
    _ = s.hold(0, 100);
    try testing.expectEqual(bit(.left) | bit(.up), s.sample(btn(.a) | btn(.up)));
}

test "genesis: A+B is the cart's B, masking left/right; DOWN + A+B = crouch + jump" {
    var s: GenSim = .{};
    _ = s.hold(btn(.down), 100);
    // The left thumb presses A and B together while DOWN is held.
    _ = s.hold(btn(.down) | btn(.a) | btn(.b), 100);
    try testing.expectEqual(bit(.down) | bit(.b), s.sample(btn(.down) | btn(.a) | btn(.b)));
    try testing.expectEqual(bit(.down) | bit(.b), s.hold(btn(.down) | btn(.a) | btn(.b), 200));
    // Release B: A stays masked until it too is released (no stray left).
    _ = s.hold(btn(.down) | btn(.a), 100);
    try testing.expectEqual(bit(.down), s.sample(btn(.down) | btn(.a)));
    _ = s.hold(0, 100);
    try testing.expectEqual(bit(.left), s.sample(btn(.a)));
}

test "genesis: UP+DOWN tap = one Start, never Select" {
    var s: GenSim = .{};
    _ = s.hold(0, 100);
    var seen = s.hold(btn(.up) | btn(.down), 150);
    seen |= s.hold(0, 200);
    try testing.expect(seen & bit(.start) != 0);
    try testing.expect(seen & bit(.select) == 0);
    try testing.expect(seen & (bit(.a) | bit(.b) | bit(.left) | bit(.right)) == 0);
    try testing.expectEqual(@as(u16, 0), s.sample(0));
}

test "genesis: UP+DOWN held = Select held until release (the cart menu), never Start" {
    var s: GenSim = .{};
    _ = s.hold(0, 100);
    _ = s.hold(btn(.up) | btn(.down), 320);
    // From 300 ms on: Select, held; up/down are masked by the chord.
    try testing.expectEqual(bit(.select), s.sample(btn(.up) | btn(.down)));
    // Held 600 ms more: the cart's 15 updates (500 ms) of Select pass.
    var presents_with_select: u32 = 0;
    var i: u32 = 0;
    while (i < 18) : (i += 1) {
        const out = s.sample(btn(.up) | btn(.down));
        try testing.expect(out & bit(.start) == 0);
        if (out & bit(.select) != 0) presents_with_select += 1;
    }
    try testing.expectEqual(@as(u32, 18), presents_with_select);
    // Released: Select drops (after its stretch), no Start.
    _ = s.hold(0, 100);
    try testing.expectEqual(@as(u16, 0), s.sample(0));
}

test "genesis: never click, and Start/Select only from UP+DOWN" {
    // Every combination of the five buttons held for a while.
    var held: u8 = 0;
    while (held < 32) : (held += 1) {
        var s: GenSim = .{};
        const seen = s.hold(held, 1000);
        try testing.expect(seen & bit(.click) == 0);
        const ud = btn(.up) | btn(.down);
        if (held & ud != ud) try testing.expect(seen & (bit(.start) | bit(.select)) == 0);
    }
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

/// Holds `held` for `n` presents of 16 ms; returns the last output.
fn hold_for(s: *Sim, held: u8, n: usize) u16 {
    var out: u16 = 0;
    for (0..n) |_| out = s.step(held, 16);
    return out;
}

test "latch: a double tap latches, a touch unlatches" {
    var s: Sim = .{ .m = .init(&snoutenstein) };
    // A single tap walks while held, then stops.
    try testing.expectEqual(bit(.up), hold_for(&s, btn(.up), 5));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 30));
    // Double tap: tap 80 ms, gap 80 ms, press: latched from the press on,
    // and the walk survives the release.
    _ = hold_for(&s, btn(.up), 5);
    _ = hold_for(&s, 0, 5);
    try testing.expectEqual(bit(.up), s.step(btn(.up), 16));
    _ = hold_for(&s, btn(.up), 4);
    try testing.expectEqual(bit(.up), hold_for(&s, 0, 60));
    // Fire and turn while autowalking.
    try testing.expectEqual(bit(.up) | bit(.a) | bit(.left), hold_for(&s, btn(.c) | btn(.a), 20));
    try testing.expectEqual(bit(.up) | bit(.right), hold_for(&s, btn(.b), 20));
    _ = hold_for(&s, 0, 5);
    // Touch UP: manual walk while held, nothing after the release, and that
    // touch is spent (a quick press after it does not latch again).
    try testing.expectEqual(bit(.up), hold_for(&s, btn(.up), 4));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 4));
    try testing.expectEqual(bit(.up), hold_for(&s, btn(.up), 4));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 60));
}

test "latch: slow taps and long presses never latch" {
    var s: Sim = .{ .m = .init(&snoutenstein) };
    // Gap longer than double_ms (250 ms).
    _ = hold_for(&s, btn(.up), 5);
    _ = hold_for(&s, 0, 20);
    _ = hold_for(&s, btn(.up), 5);
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 30));
    // A long walk, a short stop, walk again: the first press was no tap.
    _ = hold_for(&s, btn(.up), 40);
    _ = hold_for(&s, 0, 3);
    _ = hold_for(&s, btn(.up), 5);
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 30));
}

test "latch: DOWN and the A+B rewind drop it" {
    const latch_on = struct {
        fn f(s: *Sim) !void {
            _ = hold_for(s, btn(.up), 3);
            _ = hold_for(s, 0, 3);
            _ = hold_for(s, btn(.up), 3);
            try testing.expectEqual(bit(.up), hold_for(s, 0, 30));
        }
    }.f;
    var s: Sim = .{ .m = .init(&snoutenstein) };
    try latch_on(&s);
    // DOWN: back while held (never up+down), then stopped.
    try testing.expectEqual(bit(.down), hold_for(&s, btn(.down), 10));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 30));

    try latch_on(&s);
    // A then B (rewind): the first frame turns, then the chord is b alone,
    // and walking does not resume after the rewind.
    _ = s.step(btn(.a), 16);
    try testing.expectEqual(bit(.b), hold_for(&s, btn(.a) | btn(.b), 60));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 30));
}

test "snoutenstein: rewind, weapon, pause" {
    try testing.expectEqual(&snoutenstein, for_cart("snoutenstein"));
    var s: Sim = .{ .m = .init(&snoutenstein) };
    // A+B pressed together: b only, held as long as the chord.
    try testing.expectEqual(bit(.b), hold_for(&s, btn(.a) | btn(.b), 120));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 10));
    // Turn while firing: the left thumb rocks, C holds.
    try testing.expectEqual(bit(.left) | bit(.a), hold_for(&s, btn(.a) | btn(.c), 10));
    try testing.expectEqual(bit(.right) | bit(.a), hold_for(&s, btn(.b) | btn(.c), 10));
    _ = hold_for(&s, 0, 10);
    // UP+DOWN tap: one select pulse of 2 presents, no walking, no start.
    try testing.expectEqual(@as(u16, 0), hold_for(&s, btn(.up) | btn(.down), 6));
    try testing.expectEqual(bit(.select), s.step(0, 16));
    try testing.expectEqual(bit(.select), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 10));
    // UP+DOWN hold: start from 500 ms, never select.
    try testing.expectEqual(@as(u16, 0), hold_for(&s, btn(.up) | btn(.down), 30));
    try testing.expectEqual(bit(.start), hold_for(&s, btn(.up) | btn(.down), 3));
    try testing.expectEqual(@as(u16, 0), hold_for(&s, 0, 10));
    // Never click, never select+start together.
    for (0..32) |combo_usize| {
        var t: Sim = .{ .m = .init(&snoutenstein) };
        for (0..60) |_| {
            const out = t.step(@intCast(combo_usize), 16);
            try testing.expectEqual(@as(u16, 0), out & bit(.click));
            try testing.expect(out & (bit(.select) | bit(.start)) != bit(.select) | bit(.start));
        }
    }
}

/// A 20 fps cart behind a fast OS loop: the mapper runs every 1 ms, the
/// cart samples the Controls once per 50 ms update (then presents) and
/// detects edges the way snouty-reflections' input.zig does. Counts what
/// the cart saw.
const Cart20 = struct {
    m: Mapper,
    t_ms: u64 = 0,
    presents: u32 = 0,
    out: u16 = 0,
    prev: u16 = 0,
    /// Rising edges seen by the cart, per Controls bit.
    edges: [16]u32 = @splat(0),
    /// Updates on which the cart saw the bit held, per Controls bit.
    held_updates: [16]u32 = @splat(0),

    fn run(c: *Cart20, held: u8, dur_ms: u64) void {
        for (0..dur_ms) |_| {
            c.t_ms += 1;
            c.out = c.m.update(held, c.t_ms * ms, c.presents);
            if (c.t_ms % 50 == 0) {
                // A cart update: input.update(controls), then a present.
                for (0..16) |bi| {
                    const b = @as(u16, 1) << @intCast(bi);
                    if (c.out & b != 0) c.held_updates[bi] += 1;
                    if (c.out & b != 0 and c.prev & b == 0) c.edges[bi] += 1;
                }
                c.prev = c.out;
                c.presents += 1;
            }
        }
    }

    fn edges_of(c: *const Cart20, ctl: Control) u32 {
        return c.edges[@intFromEnum(ctl)];
    }

    fn held_of(c: *const Cart20, ctl: Control) u32 {
        return c.held_updates[@intFromEnum(ctl)];
    }
};

test "reflections: for_cart picks its map" {
    try testing.expectEqual(&snouty_reflections, for_cart("snouty-reflections"));
    try testing.expectEqual(&snouty_run, for_cart("snouty-run"));
}

test "reflections: C freezes on the first update, no delay" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(0, 10);
    // Pressed 40 ms before an update: the cart sees A on that update.
    c.run(btn(.c), 40);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    c.run(btn(.c), 500);
    c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    // A second press unfreezes: a second edge.
    c.run(btn(.c), 30);
    c.run(0, 100);
    try testing.expectEqual(@as(u32, 2), c.edges_of(.a));
}

test "reflections: a quick C tap between updates still freezes once" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(0, 5);
    c.run(btn(.c), 10); // 5..15 ms; the next update is at 50 ms
    c.run(0, 300);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
}

test "reflections: A held orbits left, never a preset change" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(btn(.a), 500);
    try testing.expect(c.held_of(.left) >= 8);
    try testing.expectEqual(@as(u32, 0), c.held_of(.right));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.select));
}

test "reflections: A+B 30 ms apart = one preset change, no orbit leak" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(0, 20);
    c.run(btn(.a), 30);
    c.run(btn(.a) | btn(.b), 400);
    // Released one at a time: the one still held stays masked.
    c.run(btn(.b), 200);
    c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.select));
    try testing.expectEqual(@as(u32, 0), c.held_of(.left));
    try testing.expectEqual(@as(u32, 0), c.held_of(.right));
}

test "reflections: UP+DOWN = one dither step, no height change" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(btn(.down), 40);
    c.run(btn(.up) | btn(.down), 300);
    c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.b));
    try testing.expectEqual(@as(u32, 0), c.held_of(.up));
    try testing.expectEqual(@as(u32, 0), c.held_of(.down));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.a));
}

test "reflections: orbit and height together, C freezes while steering" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(btn(.a) | btn(.up), 300);
    try testing.expect(c.held_of(.left) >= 4);
    try testing.expect(c.held_of(.up) >= 4);
    c.run(btn(.a) | btn(.up) | btn(.c), 100);
    c.run(0, 100);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.select));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.b));
}

test "reflections: a chord formed after a long hold changes the preset once" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(btn(.a), 300);
    const left = c.held_of(.left);
    try testing.expect(left >= 4);
    c.run(btn(.a) | btn(.b), 300);
    c.run(0, 100);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.select));
    // The orbit stops as soon as the chord forms (left was level, so it
    // has no pulse stretch to run out).
    try testing.expectEqual(left, c.held_of(.left));
    try testing.expectEqual(@as(u32, 0), c.held_of(.right));
}

test "reflections: START and click are never sent" {
    var c: Cart20 = .{ .m = .init(&snouty_reflections) };
    c.run(btn(.c), 2000);
    c.run(btn(.a) | btn(.b) | btn(.up) | btn(.down), 1000);
    c.run(0, 100);
    try testing.expectEqual(@as(u32, 0), c.held_of(.start));
    try testing.expectEqual(@as(u32, 0), c.held_of(.click));
}

test "snouty-maze: direction buttons are direct, at once" {
    try testing.expectEqual(&snouty_maze, for_cart("snouty-maze"));
    const cases = [_]struct { Button, u16 }{
        .{ .a, bit(.left) },
        .{ .b, bit(.right) },
        .{ .up, bit(.up) },
        .{ .down, bit(.down) },
    };
    for (cases) |c| {
        var s: Sim = .{ .m = .init(&snouty_maze) };
        try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        try testing.expectEqual(@as(u16, 0), s.step(0, 16));
    }
}

test "snouty-maze: C tap skips, C hold toggles the name strip once" {
    // Tap, 100 ms: nothing while held, then A for 2 presents, never start.
    var s: Sim = .{ .m = .init(&snouty_maze) };
    for (0..6) |_| try testing.expectEqual(@as(u16, 0), s.step(btn(.c), 16));
    try testing.expectEqual(bit(.a), s.step(0, 16));
    try testing.expectEqual(bit(.a), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));

    // Hold, 1 s: start from 600 ms until release (one rising edge, so one
    // toggle in the cart), no A on release.
    var h: Sim = .{ .m = .init(&snouty_maze) };
    var rises: u32 = 0;
    var prev: u16 = 0;
    for (0..62) |i| {
        const out = h.step(btn(.c), 16);
        try testing.expectEqual(@as(u16, 0), out & bit(.a));
        if (i < 36) try testing.expectEqual(@as(u16, 0), out);
        if (out & bit(.start) != 0 and prev & bit(.start) == 0) rises += 1;
        prev = out;
    }
    try testing.expectEqual(@as(u32, 1), rises);
    try testing.expectEqual(bit(.start), prev);
    try testing.expectEqual(@as(u16, 0), h.step(0, 16));
    try testing.expectEqual(@as(u16, 0), h.step(0, 16));

    // In between (500 ms): neither.
    var m: Sim = .{ .m = .init(&snouty_maze) };
    for (0..31) |_| try testing.expectEqual(@as(u16, 0), m.step(btn(.c), 16));
    try testing.expectEqual(@as(u16, 0), m.step(0, 16));
    try testing.expectEqual(@as(u16, 0), m.step(0, 16));
}

test "snouty-maze: a quick tap of C still reaches the cart" {
    var s: Sim = .{ .m = .init(&snouty_maze) };
    _ = s.step(0, 16);
    s.t += 3 * ms;
    try testing.expectEqual(@as(u16, 0), s.m.update(btn(.c), s.t, s.presents));
    s.t += 3 * ms;
    try testing.expectEqual(bit(.a), s.m.update(0, s.t, s.presents));
    try testing.expectEqual(bit(.a), s.step(0, 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "snouty-maze: nothing masked, never b, select or click" {
    // Every combination held for 200 ms: exactly the direct bits of the
    // direction buttons (C adds nothing before its hold), never a forbidden bit.
    const forbidden = bit(.b) | bit(.select) | bit(.click);
    for (0..32) |combo_usize| {
        const combo: u8 = @intCast(combo_usize);
        var expect: u16 = 0;
        if (combo & btn(.a) != 0) expect |= bit(.left);
        if (combo & btn(.b) != 0) expect |= bit(.right);
        if (combo & btn(.up) != 0) expect |= bit(.up);
        if (combo & btn(.down) != 0) expect |= bit(.down);
        var s: Sim = .{ .m = .init(&snouty_maze) };
        var out: u16 = 0;
        for (0..12) |_| {
            out = s.step(combo, 16);
            try testing.expectEqual(@as(u16, 0), out & forbidden);
        }
        try testing.expectEqual(expect, out);
        // Release everything: at most the C tap pulse, still nothing forbidden.
        out = s.step(0, 16);
        try testing.expectEqual(@as(u16, 0), out & forbidden);
        try testing.expectEqual(if (combo & btn(.c) != 0) bit(.a) else 0, out);
    }
}

/// A model of a cart's once-per-frame edge detector (snouty-bugs' `meta`,
/// which starts at zero): counts the rising edges of `c` over the presents
/// it is fed.
const Edges = struct {
    prev: u16 = 0,
    count: u32 = 0,

    fn feed(e: *Edges, out: u16, c: Control) void {
        if (out & bit(c) != 0 and e.prev & bit(c) == 0) e.count += 1;
        e.prev = out;
    }
};

test "snouty-bugs: nothing is latched at boot, so the title is not skipped" {
    try testing.expectEqual(&snouty_bugs, for_cart("snouty-bugs"));
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    var e: Edges = .{};
    for (0..120) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 0), e.count);
    // Steering alone never fires either.
    for (0..30) |_| try testing.expectEqual(bit(.left) | bit(.up), s.step(btn(.a) | btn(.up), 16));
}

test "snouty-bugs: one tap of C starts the game and fires from then on" {
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    var e: Edges = .{};
    e.feed(s.step(0, 16), .a);
    // A 3 ms tap between two presents.
    s.t += 3 * ms;
    e.feed(s.m.update(btn(.c), s.t, s.presents), .a);
    s.t += 3 * ms;
    _ = s.m.update(0, s.t, s.presents);
    for (0..600) |_| {
        const out = s.step(0, 16);
        try testing.expect(out & bit(.a) != 0);
        e.feed(out, .a);
    }
    try testing.expectEqual(@as(u32, 1), e.count);
}

test "snouty-bugs: every later C is a fresh press of A, then autofire again" {
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    var e: Edges = .{};
    e.feed(s.step(btn(.c), 16), .a);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    e.count = 0; // the latching press
    try testing.expect(e.prev & bit(.a) != 0);
    // A held press of C (5 frames), then a sub-present tap: each one drops
    // A for at least one present and raises it again.
    for (0..5) |_| e.feed(s.step(btn(.c), 16), .a);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 1), e.count);
    s.t += 2 * ms;
    e.feed(s.m.update(btn(.c), s.t, s.presents), .a);
    s.t += 2 * ms;
    _ = s.m.update(0, s.t, s.presents);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 2), e.count);
    try testing.expect(e.prev & bit(.a) != 0);
    // Two taps on consecutive presents still give two edges.
    _ = s.step(btn(.c), 16);
    e.feed(s.step(0, 16), .a);
    e.feed(s.step(btn(.c), 16), .a);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expect(e.count >= 3);
    try testing.expect(e.prev & bit(.a) != 0);
}

test "snouty-bugs: steer, rewind and pause while autofire runs" {
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    _ = s.step(btn(.c), 16);
    for (0..5) |_| _ = s.step(0, 16);
    const fire = bit(.a);
    // Both thumbs steering: a diagonal plus fire, no hand on C.
    for (0..10) |_| try testing.expectEqual(fire | bit(.right) | bit(.down), s.step(btn(.b) | btn(.down), 16));
    for (0..10) |_| try testing.expectEqual(fire | bit(.left) | bit(.up), s.step(btn(.a) | btn(.up), 16));
    // A+B: rewind (the cart's B) for every frame of the hold, no left/right.
    _ = s.step(btn(.a) | btn(.b) | btn(.up), 16);
    for (0..120) |_| {
        const out = s.step(btn(.a) | btn(.b) | btn(.up), 16);
        try testing.expectEqual(fire | bit(.b) | bit(.up), out);
    }
    for (0..5) |_| _ = s.step(0, 16);
    // UP+DOWN: Start (pause), no up/down.
    _ = s.step(btn(.up) | btn(.down), 16);
    try testing.expectEqual(fire | bit(.start), s.step(btn(.up) | btn(.down), 16));
    try testing.expectEqual(fire, s.step(0, 16));
}

test "snouty-bugs: Hardcore (A+B) from the title, at boot or after a game" {
    // At boot: B rises, A never does (the title checks A first).
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    var a: Edges = .{};
    var b: Edges = .{};
    for (0..5) |_| {
        const out = s.step(btn(.a) | btn(.b), 16);
        a.feed(out, .a);
        b.feed(out, .b);
    }
    try testing.expectEqual(@as(u32, 0), a.count);
    try testing.expectEqual(@as(u32, 1), b.count);
    // After a game with autofire latched: A is steady, so again only B rises.
    var t: Sim = .{ .m = .init(&snouty_bugs) };
    _ = t.step(btn(.c), 16);
    for (0..5) |_| _ = t.step(0, 16);
    a = .{ .prev = bit(.a) };
    b = .{};
    for (0..5) |_| {
        const out = t.step(btn(.b) | btn(.a), 16);
        a.feed(out, .a);
        b.feed(out, .b);
    }
    try testing.expectEqual(@as(u32, 0), a.count);
    try testing.expectEqual(@as(u32, 1), b.count);
}

test "snouty-bugs: a HOME restart (fresh mapper) clears the latch" {
    var s: Sim = .{ .m = .init(&snouty_bugs) };
    _ = s.step(btn(.c), 16);
    for (0..5) |_| try testing.expect(s.step(0, 16) & bit(.a) != 0);
    s.m = .init(&snouty_bugs);
    s.presents = 0;
    for (0..5) |_| try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "snouty-bugs: never select or click, for any buttons" {
    for (0..32) |combo_usize| {
        const combo: u8 = @intCast(combo_usize);
        var s: Sim = .{ .m = .init(&snouty_bugs) };
        for (0..10) |_| {
            const out = s.step(combo, 16);
            try testing.expectEqual(@as(u16, 0), out & (bit(.select) | bit(.click)));
        }
    }
}

/// snouty-flyover behind a fast OS loop: the mapper runs every 1 ms, the
/// cart updates every 33 ms (its 30 fps lock) and runs camera.pilot()'s
/// input rules: input.zig edges, START (edge) toggles the autopilot, and
/// any held direction, A or B switches to manual flight.
const Flyover30 = struct {
    m: Mapper = .init(&snouty_flyover),
    t_ms: u64 = 0,
    presents: u32 = 0,
    out: u16 = 0,
    prev: u16 = 0,
    autopilot: bool = true,
    edges: [16]u32 = @splat(0),
    held_updates: [16]u32 = @splat(0),

    const manual_bits = bit(.left) | bit(.right) | bit(.up) | bit(.down) | bit(.a) | bit(.b);

    fn run(c: *Flyover30, held: u8, dur_ms: u64) !void {
        for (0..dur_ms) |_| {
            c.t_ms += 1;
            c.out = c.m.update(held, c.t_ms * ms, c.presents);
            if (c.t_ms % 33 != 0) continue;
            // The OS owns Start+Select on the SYCL badge; never send both.
            try testing.expect(c.out & (bit(.select) | bit(.start)) != bit(.select) | bit(.start));
            try testing.expectEqual(@as(u16, 0), c.out & bit(.click));
            for (0..16) |bi| {
                const b = @as(u16, 1) << @intCast(bi);
                if (c.out & b != 0) c.held_updates[bi] += 1;
                if (c.out & b != 0 and c.prev & b == 0) c.edges[bi] += 1;
            }
            if (c.out & bit(.start) != 0 and c.prev & bit(.start) == 0) c.autopilot = !c.autopilot;
            if (c.out & manual_bits != 0) c.autopilot = false;
            c.prev = c.out;
            c.presents += 1;
        }
    }

    fn edges_of(c: *const Flyover30, ctl: Control) u32 {
        return c.edges[@intFromEnum(ctl)];
    }

    fn held_of(c: *const Flyover30, ctl: Control) u32 {
        return c.held_updates[@intFromEnum(ctl)];
    }
};

test "snouty-flyover: one control per button; C at once, the rest after chord_ms" {
    try testing.expectEqual(&snouty_flyover, for_cart("snouty-flyover"));
    const cases = [_]struct { Button, u16 }{
        .{ .a, bit(.left) },
        .{ .b, bit(.right) },
        .{ .up, bit(.down) }, // climb
        .{ .down, bit(.up) }, // dive
    };
    for (cases) |c| {
        var s: Sim = .{ .m = .init(&snouty_flyover) };
        // 0, 16, 32 and 48 ms into the press: inside the 60 ms chord delay.
        for (0..4) |_| try testing.expectEqual(@as(u16, 0), s.step(btn(c[0]), 16));
        // From 64 ms: set while held.
        for (0..30) |_| try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        _ = s.step(0, 16);
        _ = s.step(0, 16);
        try testing.expectEqual(@as(u16, 0), s.step(0, 16));
    }
    // C is the cart's B with no delay, held as long as C.
    var s: Sim = .{ .m = .init(&snouty_flyover) };
    for (0..30) |_| try testing.expectEqual(bit(.b), s.step(btn(.c), 16));
    try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "snouty-flyover: quick taps still reach a 30 fps cart" {
    // A 5 ms tap of C, and a 20 ms tap of A (inside chord_ms), between updates.
    var c: Flyover30 = .{};
    try c.run(0, 40);
    try c.run(btn(.c), 5);
    try c.run(0, 200);
    try c.run(btn(.a), 20);
    try c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.b));
    try testing.expectEqual(@as(u32, 1), c.edges_of(.left));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.a));
}

test "snouty-flyover: A+B 30 ms apart = boost while held, no bank leak" {
    var c: Flyover30 = .{};
    try c.run(0, 20);
    try c.run(btn(.b), 30);
    try c.run(btn(.a) | btn(.b), 1000);
    // Pitch while boosting (right thumb on UP).
    try c.run(btn(.a) | btn(.b) | btn(.up), 300);
    // Lifted one at a time: the one still held stays masked.
    try c.run(btn(.a), 200);
    try c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    try testing.expect(c.held_of(.a) >= 36);
    try testing.expect(c.held_of(.down) >= 6);
    try testing.expectEqual(@as(u32, 0), c.held_of(.left));
    try testing.expectEqual(@as(u32, 0), c.held_of(.right));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.b));
    try testing.expect(!c.autopilot);
}

test "snouty-flyover: UP+DOWN tap skips and keeps the autopilot" {
    var c: Flyover30 = .{};
    try c.run(0, 100);
    // DOWN 40 ms before UP, held 200 ms: one SELECT edge after the release.
    try c.run(btn(.down), 40);
    try c.run(btn(.up) | btn(.down), 200);
    try c.run(0, 300);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.select));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.start));
    try testing.expectEqual(@as(u32, 0), c.held_of(.up));
    try testing.expectEqual(@as(u32, 0), c.held_of(.down));
    try testing.expect(c.autopilot);
}

test "snouty-flyover: UP+DOWN hold toggles the autopilot once per hold" {
    var c: Flyover30 = .{};
    try c.run(0, 100);
    // On -> off: UP first, DOWN 30 ms later, held 1 s.
    try c.run(btn(.up), 30);
    try c.run(btn(.up) | btn(.down), 1000);
    try c.run(btn(.down), 100);
    try c.run(0, 300);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.start));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.select));
    try testing.expectEqual(@as(u32, 0), c.held_of(.up) + c.held_of(.down));
    try testing.expect(!c.autopilot);
    // Off -> on.
    try c.run(btn(.up) | btn(.down), 800);
    try c.run(0, 300);
    try testing.expectEqual(@as(u32, 2), c.edges_of(.start));
    try testing.expect(c.autopilot);
}

test "snouty-flyover: bank, pitch and the verb together" {
    var c: Flyover30 = .{};
    try c.run(btn(.a) | btn(.down), 300);
    try c.run(btn(.a) | btn(.down) | btn(.c), 100);
    try c.run(btn(.b) | btn(.up), 300);
    try c.run(0, 100);
    try testing.expect(c.held_of(.left) >= 10);
    try testing.expect(c.held_of(.up) >= 10); // DOWN dives
    try testing.expect(c.held_of(.right) >= 7);
    try testing.expect(c.held_of(.down) >= 7); // UP climbs
    try testing.expectEqual(@as(u32, 1), c.edges_of(.b));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.a) + c.edges_of(.select) + c.edges_of(.start));
}

test "snouty-flyover: never click, never select with start, for any buttons" {
    // Flyover30.run checks both on every update.
    for (0..32) |combo_usize| {
        var c: Flyover30 = .{};
        try c.run(@intCast(combo_usize), 1200);
        try c.run(0, 300);
    }
}

/// snouty-zero behind a fast OS loop: the mapper runs every 1 ms and the cart
/// updates at 60 Hz (every 16,667 us), detecting edges the way its input.zig
/// does. Counts what the cart saw.
const Zero60 = struct {
    m: Mapper = .init(&snouty_zero),
    t_us: u64 = 0,
    next_us: u64 = 16_667,
    presents: u32 = 0,
    out: u16 = 0,
    prev: u16 = 0,
    edges: [16]u32 = @splat(0),
    held_updates: [16]u32 = @splat(0),

    fn run(c: *Zero60, held: u8, dur_ms: u64) !void {
        for (0..dur_ms) |_| {
            c.t_us += 1000;
            c.out = c.m.update(held, c.t_us, c.presents);
            if (c.t_us < c.next_us) continue;
            c.next_us += 16_667;
            // The OS owns Start+Select and click on the SYCL badge; the cart
            // never reads Select. None of them is ever sent.
            try testing.expectEqual(@as(u16, 0), c.out & (bit(.select) | bit(.click)));
            for (0..16) |bi| {
                const b = @as(u16, 1) << @intCast(bi);
                if (c.out & b != 0) c.held_updates[bi] += 1;
                if (c.out & b != 0 and c.prev & b == 0) c.edges[bi] += 1;
            }
            c.prev = c.out;
            c.presents += 1;
        }
    }

    fn edges_of(c: *const Zero60, ctl: Control) u32 {
        return c.edges[@intFromEnum(ctl)];
    }

    fn held_of(c: *const Zero60, ctl: Control) u32 {
        return c.held_updates[@intFromEnum(ctl)];
    }
};

test "zero: for_cart; A/B steer at once, UP/DOWN from 60 ms, C latches the throttle" {
    try testing.expectEqual(&snouty_zero, for_cart("snouty-zero"));
    const instant = [_]struct { Button, u16 }{ .{ .a, bit(.left) }, .{ .b, bit(.right) } };
    for (instant) |c| {
        var s: Sim = .{ .m = .init(&snouty_zero) };
        for (0..30) |_| try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        try testing.expectEqual(@as(u16, 0), s.step(0, 16));
    }
    const delayed = [_]struct { Button, u16 }{ .{ .up, bit(.up) }, .{ .down, bit(.down) } };
    for (delayed) |c| {
        var s: Sim = .{ .m = .init(&snouty_zero) };
        // 0, 16, 32 and 48 ms into the press: inside its 60 ms chord delay.
        for (0..4) |_| try testing.expectEqual(@as(u16, 0), s.step(btn(c[0]), 16));
        for (0..30) |_| try testing.expectEqual(c[1], s.step(btn(c[0]), 16));
        _ = s.step(0, 16);
        _ = s.step(0, 16);
        try testing.expectEqual(@as(u16, 0), s.step(0, 16));
    }
    // C: the throttle (the cart's A) from the press on, and it stays on.
    var s: Sim = .{ .m = .init(&snouty_zero) };
    try testing.expectEqual(bit(.a), s.step(btn(.c), 16));
    for (0..600) |_| try testing.expectEqual(bit(.a), s.step(0, 16));
}

test "zero: nothing latched at boot; steer, Overclock and brake under the latched throttle" {
    var c: Zero60 = .{};
    try c.run(0, 2000);
    try testing.expectEqual(@as(u32, 0), c.held_of(.a));
    // Steering alone never accelerates.
    try c.run(btn(.a), 300);
    try testing.expectEqual(@as(u32, 0), c.held_of(.a));
    try c.run(0, 100);
    // One quick C tap (5 ms): the throttle is on for good.
    try c.run(btn(.c), 5);
    try c.run(0, 1000);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    // Both thumbs busy, no hand on C: steer left + brake (the tight turn),
    // then steer right + Overclock, the throttle on throughout.
    try c.run(btn(.a) | btn(.down), 500);
    try testing.expect(c.out == bit(.a) | bit(.left) | bit(.down));
    try c.run(0, 50);
    try c.run(btn(.b) | btn(.up), 500);
    try testing.expect(c.out == bit(.a) | bit(.right) | bit(.up));
    try c.run(0, 100);
    try testing.expectEqual(bit(.a), c.out);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
    try testing.expectEqual(@as(u32, 1), c.edges_of(.up));
    try testing.expectEqual(@as(u32, 0), c.held_of(.b) + c.held_of(.start));
}

test "zero: every later C is a fresh A press (menus confirm), then the throttle again" {
    var s: Sim = .{ .m = .init(&snouty_zero) };
    var e: Edges = .{};
    for (0..5) |_| e.feed(s.step(0, 16), .a);
    // The first C: the title (Tufty build: A or Start) and the throttle.
    e.feed(s.step(btn(.c), 16), .a);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 1), e.count);
    // Menu confirms: a held C, a sub-present tap, taps on consecutive
    // presents. Each one is an A edge; A is back on after each.
    for (0..5) |_| e.feed(s.step(btn(.c), 16), .a);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 2), e.count);
    s.t += 2 * ms;
    e.feed(s.m.update(btn(.c), s.t, s.presents), .a);
    s.t += 2 * ms;
    _ = s.m.update(0, s.t, s.presents);
    for (0..10) |_| e.feed(s.step(0, 16), .a);
    try testing.expectEqual(@as(u32, 3), e.count);
    try testing.expect(e.prev & bit(.a) != 0);
    // A HOME restart (a fresh mapper) clears the throttle.
    s.m = .init(&snouty_zero);
    s.presents = 0;
    for (0..5) |_| try testing.expectEqual(@as(u16, 0), s.step(0, 16));
}

test "zero: UP+DOWN inside 60 ms = one Start, no Overclock, no cursor move" {
    // UP first by 40 ms, then DOWN first by 50 ms, then held 1 s: one Start
    // edge each (pause, then resume), never up or down.
    var c: Zero60 = .{};
    try c.run(btn(.c), 20);
    try c.run(0, 100);
    try c.run(btn(.up), 40);
    try c.run(btn(.up) | btn(.down), 200);
    try c.run(0, 300);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.start));
    try c.run(btn(.down), 50);
    try c.run(btn(.up) | btn(.down), 1000);
    // Released one at a time: the one still held stays masked.
    try c.run(btn(.up), 200);
    try c.run(0, 300);
    try testing.expectEqual(@as(u32, 2), c.edges_of(.start));
    try testing.expectEqual(@as(u32, 0), c.held_of(.up) + c.held_of(.down));
    // The throttle never dropped: one A edge, from the C press.
    try testing.expectEqual(@as(u32, 1), c.edges_of(.a));
}

test "zero: a quick UP tap still fires one Overclock" {
    // 20 ms (inside the chord delay): sent as a pulse on the release.
    var c: Zero60 = .{};
    try c.run(0, 30);
    try c.run(btn(.up), 20);
    try c.run(0, 200);
    try testing.expectEqual(@as(u32, 1), c.edges_of(.up));
    // A long hold: one edge (the cart fires on the edge).
    try c.run(btn(.up), 800);
    try c.run(0, 200);
    try testing.expectEqual(@as(u32, 2), c.edges_of(.up));
    try testing.expectEqual(@as(u32, 0), c.edges_of(.start));
}

test "zero: A+B rewinds on every update of the hold, steering masked" {
    var c: Zero60 = .{};
    try c.run(btn(.c), 20);
    try c.run(0, 100);
    // A 10 ms before B: A's steer may leak for its 2-present stretch, no more.
    try c.run(btn(.a), 10);
    try c.run(btn(.a) | btn(.b), 1000);
    const b_updates = c.held_of(.b);
    try testing.expect(b_updates >= 58);
    try testing.expect(c.held_of(.left) <= 2);
    // Release B first: A stays masked until it too is released.
    try c.run(btn(.a), 200);
    try c.run(0, 100);
    try testing.expect(c.held_of(.left) <= 2);
    try testing.expectEqual(@as(u32, 0), c.held_of(.right));
    try testing.expectEqual(@as(u32, 1), c.edges_of(.b));
    // DOWN held through the rewind still reaches the cart (it ignores it).
    try c.run(btn(.a) | btn(.b) | btn(.down), 300);
    try testing.expect(c.out & bit(.b) != 0);
    try testing.expectEqual(@as(u32, 0), c.edges_of(.start));
}

test "zero: never select or click; Start only from UP+DOWN" {
    // Zero60.run checks select and click on every update.
    var held: u8 = 0;
    while (held < 32) : (held += 1) {
        var c: Zero60 = .{};
        try c.run(held, 1200);
        try c.run(0, 300);
        const ud = btn(.up) | btn(.down);
        if (held & ud != ud) try testing.expectEqual(@as(u32, 0), c.held_of(.start));
        if (held & ud == ud) try testing.expectEqual(@as(u32, 0), c.held_of(.up) + c.held_of(.down));
    }
}

test "control bits match the SYCL Controls layout" {
    // api.zig: packed struct(u16) { start, select, a, b, click, up, down, left, right, _pad: u7 }
    try testing.expectEqual(@as(u16, 0x0001), bit(.start));
    try testing.expectEqual(@as(u16, 0x0004), bit(.a));
    try testing.expectEqual(@as(u16, 0x0100), bit(.right));
}
