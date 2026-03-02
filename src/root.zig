pub const main = @import("main.zig");
pub const manifest = @import("core/manifest.zig");
pub const paths = @import("core/paths.zig");
pub const platform = @import("core/platform.zig");
pub const state = @import("core/state.zig");

test {
    _ = main;
    _ = manifest;
    _ = paths;
    _ = platform;
    _ = state;
}
