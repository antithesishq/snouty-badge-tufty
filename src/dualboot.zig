//! The dual-boot host modules (docs/DUALBOOT.md), for tools/dualboot_uf2.zig.
//! A root at src/ so that pack.zig can reach uf2_check.zig.
pub const layout = @import("dualboot/layout.zig");
pub const pack = @import("dualboot/pack.zig");
pub const uf2_check = @import("uf2_check.zig");
