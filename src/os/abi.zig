/// The SYCL cart ABI, OS side, as the Tufty OS implements it.
///
/// A mirror of sycl-badge src/os/cart/os_abi.zig and ipc/mailbox.zig at
/// a6ce19f (the version snouty-badge pins). It is copied rather than
/// imported because os_abi.zig pulls in the whole cart API. The host tests
/// below pin every offset to the values os_abi.zig documents, so a layout
/// slip fails `zig build test`.
const std = @import("std");

pub const screen_width = 160;
pub const screen_height = 128;

// ---- RAM map (sycl-badge src/os/linker.ld, src/cart/cart_ram.ld) ----

/// Core 1 / cart RAM ("process_ram"). The OS must keep out of it.
pub const process_ram_start: u32 = 0x2002_0000;
pub const process_ram_end: u32 = 0x2008_0000;
/// RAM carts are linked to start here (cart_ram.ld ORIGIN), right after the IPC block.
pub const cart_ram_origin: u32 = 0x2003_5100;
/// A RAM cart starts with MSP at the end of process RAM (os/cart.zig).
pub const cart_initial_sp: u32 = process_ram_end;

// ---- Cart descriptor ----

pub const CART_MAGIC: u32 = 0x54C1_CA41;
pub const CART_VERSION_V1: u32 = 0x54C1_2601;

pub const CartDescriptorV1 = extern struct {
    magic: u32,
    version: u32,
    bss_start: u32,
    bss_end: u32,
    entry_point: u32,
};

// ---- IPC block at the start of process RAM ----

pub const Controls = packed struct(u16) {
    start: bool = false,
    select: bool = false,
    a: bool = false,
    b: bool = false,
    click: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    _pad: u7 = 0,
};

pub const Rect8 = extern struct {
    min_x: u8,
    min_y: u8,
    max_x: u8,
    max_y: u8,
};

pub const NeopixelColor = extern struct { g: u8, r: u8, b: u8 };

pub const tracy_buffer_size = 4096;

// zig fmt: off
pub const CartIPCData = extern struct {
    framebuffers: [2][screen_width][screen_height]u16, // x0..xA000, xA000..x14000
    tracy_ring: [tracy_buffer_size]u8, // x14000..x15000
    trace_buf: [0x80]u8,               // x15000..x15080
    neopixels: [5]NeopixelColor,       // x15080..x1508F
    _pad1: u8,                         // x1508F..x15090
    controls: Controls,                // x15090..x15092
    light_level: u16,                  // x15092..x15094
    user_led: bool,                    // x15094..x15095
    _pad2: u8,                         // x15095..x15096
    battery_level: u16,                // x15096..x15098
    dirty_rect: Rect8,                 // x15098..x1509C
    tone_freq: f32,                    // x1509C..x150A0
    tone_duration: f32,                // x150A0..x150A4
    tone_volume: f32,                  // x150A4..x150A8
    tone_flags: u32,                   // x150A8..x150AC
    global_volume: f32,                // x150AC..x150B0
    tracy_read_pos: u32,               // x150B0..x150B4
    _pad3: [3]u32,                     // x150B4..x150C0
    tracy_write_ctrl: u32,             // x150C0..x150C4
    _pad4: [3]u32,                     // x150C4..x150D0
    tracy_spinlock: u32,               // x150D0..x150D4
    _pad5: [3]u32,                     // x150D4..x150E0
    vsync_flags: u32,                  // x150E0..x150E4
    vsync_frame_ms: f32,               // x150E4..x150E8
    clear_color: u16,                  // x150E8..x150EA
    _pad6: u16,                        // x150EA..x150EC
};
// zig fmt: on

pub fn ipc() *volatile CartIPCData {
    return @ptrFromInt(process_ram_start);
}

// ---- Messages over the SIO FIFO (ipc/mailbox.zig MessageType) ----

pub const FRAMEBUFFER_READY: u32 = 0x2500_0001; // legacy present: buffer 0, full frame
pub const FRAMEBUFFER_DONE: u32 = 0x2500_0002; // OS -> cart: buffer is free again
pub const TYPE_TRACE: u8 = 0x26; // payload = length, text in trace_buf
pub const TYPE_TONE: u8 = 0x27; // tone_* fields
pub const TYPE_FRAMEBUFFER_READY_V2: u8 = 0x28; // PresentFlags
pub const TYPE_VOLUME: u8 = 0x29; // global_volume
pub const SYNC_TIME_REQ_CLR: u32 = 0x2a00_0001;
pub const SYNC_TIME_ACK_CLR: u32 = 0x2a00_0002;
pub const SYNC_TIME_REQ_TIME: u32 = 0x2a00_0003;

pub fn msg_type(msg: u32) u8 {
    return @truncate(msg >> 24);
}

pub const PresentFlags = packed struct(u32) {
    framebuffer_index: u1,
    has_dirty_rect: bool,
    vsync_updated: bool,
    clear_frame: bool,
    _reserved: u20 = 0,
    tag: u8 = TYPE_FRAMEBUFFER_READY_V2,
};

/// SIO spinlock the cart's tracy code takes (os_abi spin_lock_*_hw).
pub const tracy_spinlock_addr: u32 = 0xd000_0128;

// ========================================
// Tests
// ========================================

test "IPC layout matches os_abi.zig" {
    const T = CartIPCData;
    const expect = std.testing.expectEqual;
    try expect(0x00000, @offsetOf(T, "framebuffers"));
    try expect(0x14000, @offsetOf(T, "tracy_ring"));
    try expect(0x15000, @offsetOf(T, "trace_buf"));
    try expect(0x15080, @offsetOf(T, "neopixels"));
    try expect(0x15090, @offsetOf(T, "controls"));
    try expect(0x15092, @offsetOf(T, "light_level"));
    try expect(0x15094, @offsetOf(T, "user_led"));
    try expect(0x15096, @offsetOf(T, "battery_level"));
    try expect(0x15098, @offsetOf(T, "dirty_rect"));
    try expect(0x1509C, @offsetOf(T, "tone_freq"));
    try expect(0x150AC, @offsetOf(T, "global_volume"));
    try expect(0x150B0, @offsetOf(T, "tracy_read_pos"));
    try expect(0x150C0, @offsetOf(T, "tracy_write_ctrl"));
    try expect(0x150D0, @offsetOf(T, "tracy_spinlock"));
    try expect(0x150E0, @offsetOf(T, "vsync_flags"));
    try expect(0x150E4, @offsetOf(T, "vsync_frame_ms"));
    try expect(0x150E8, @offsetOf(T, "clear_color"));
    try expect(0x150EC, @sizeOf(T));
    // The cart image starts after the IPC block (cart_xip.ld reserves 0x15100).
    try std.testing.expect(process_ram_start + @sizeOf(T) <= cart_ram_origin);
}

test "present flags layout" {
    const f: PresentFlags = .{ .framebuffer_index = 1, .has_dirty_rect = true, .vsync_updated = false, .clear_frame = false };
    try std.testing.expectEqual(@as(u32, 0x2800_0003), @as(u32, @bitCast(f)));
}
