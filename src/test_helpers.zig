const std = @import("std");
const std_compat = @import("compat");
const paths_mod = @import("core/paths.zig");

pub const TempPaths = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    root: []u8,
    paths: paths_mod.Paths,

    pub fn init(allocator: std.mem.Allocator) !TempPaths {
        const tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(root);

        const paths = try paths_mod.Paths.init(allocator, root);
        errdefer {
            var owned_paths = paths;
            owned_paths.deinit(allocator);
        }

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .root = root,
            .paths = paths,
        };
    }

    pub fn deinit(self: *TempPaths) void {
        self.paths.deinit(self.allocator);
        self.allocator.free(self.root);
        self.tmp.cleanup();
        self.* = undefined;
    }

    pub fn path(self: TempPaths, allocator: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, sub_path });
    }
};

test "TempPaths creates isolated nullhub root" {
    const allocator = std.testing.allocator;

    var fixture = try TempPaths.init(allocator);
    defer fixture.deinit();

    try std.testing.expect(std.fs.path.isAbsolute(fixture.root));
    try std.testing.expectEqualStrings(fixture.root, fixture.paths.root);

    try fixture.paths.ensureDirs();

    const state_path = try fixture.path(allocator, "state.json");
    defer allocator.free(state_path);
    try std.testing.expect(std.mem.startsWith(u8, state_path, fixture.root));
}
