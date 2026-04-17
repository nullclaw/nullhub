const std = @import("std");
const std_compat = @import("compat");
const meta_api = @import("api/meta.zig");
const cli = @import("cli.zig");

pub fn run(allocator: std.mem.Allocator, opts: cli.RoutesOptions) !void {
    const output = if (opts.json)
        try meta_api.jsonAlloc(allocator)
    else
        try meta_api.textAlloc(allocator);
    defer allocator.free(output);

    var out_buf: [4096]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&out_buf);
    const w = &bw.interface;
    try w.writeAll(output);
    if (output.len == 0 or output[output.len - 1] != '\n') {
        try w.writeAll("\n");
    }
    try w.flush();
}
