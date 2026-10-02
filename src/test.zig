//! Host unit tests (`zig build test`): the hardware-free parts.
test {
    _ = @import("pattern.zig");
    _ = @import("home.zig");
    _ = @import("scaler.zig");
    _ = @import("controls_map.zig");
    _ = @import("os/abi.zig");
    _ = @import("os/cart_image.zig");
    _ = @import("arcade.zig");
    _ = @import("menu.zig");
    _ = @import("uf2_check.zig");
    _ = @import("uf2_pack.zig");
    _ = @import("fat12_image.zig");
    _ = @import("dualboot/layout.zig");
    _ = @import("dualboot/pack.zig");
}
