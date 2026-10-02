//! Host unit tests (`zig build test`): the hardware-free parts.
test {
    _ = @import("pattern.zig");
    _ = @import("home.zig");
    _ = @import("scaler.zig");
    _ = @import("controls_map.zig");
    _ = @import("os/abi.zig");
    _ = @import("os/cart_image.zig");
}
