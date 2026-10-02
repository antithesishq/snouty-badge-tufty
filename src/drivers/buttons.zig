/// Tufty 2350 front buttons: A, B, C, UP, DOWN, HOME. Active low with the
/// internal pull-ups, as Pimoroni's badgeware-cpp lib/buttons.cpp.
const microzig = @import("microzig");
const hal = microzig.hal;
const board = microzig.board;
const time = hal.time;

/// One bit per button, true = held.
pub const State = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    c: bool = false,
    up: bool = false,
    down: bool = false,
    home: bool = false,
    _pad: u2 = 0,

    pub const none: State = .{};

    pub fn bits(s: State) u8 {
        return @bitCast(s);
    }
};

const pins = .{
    board.button_a,
    board.button_b,
    board.button_c,
    board.button_up,
    board.button_down,
    board.button_home,
};

pub fn init() void {
    inline for (pins) |pin| {
        pin.set_function(.sio);
        pin.set_direction(.in);
        pin.set_pull(.up);
    }
}

fn sample() State {
    return .{
        .a = board.button_a.read() == 0,
        .b = board.button_b.read() == 0,
        .c = board.button_c.read() == 0,
        .up = board.button_up.read() == 0,
        .down = board.button_down.read() == 0,
        .home = board.button_home.read() == 0,
    };
}

/// Two samples 200 us apart, ANDed: a cheap debounce that rejects a single
/// bouncing edge (the reference's poll()).
pub fn read() State {
    const s0 = sample();
    time.sleep_us(200);
    const s1 = sample();
    return @bitCast(s0.bits() & s1.bits());
}
