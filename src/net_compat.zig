const std_compat = @import("compat");

/// Socket read wrapper used by server code and tests.
pub fn streamRead(stream: std_compat.net.Stream, buffer: []u8) !usize {
    return stream.read(buffer);
}

/// Socket write wrapper used by server code and tests.
pub fn streamWrite(stream: std_compat.net.Stream, data: []const u8) !usize {
    return stream.write(data);
}

/// Write all data to a socket.
pub fn streamWriteAll(stream: std_compat.net.Stream, data: []const u8) !void {
    return stream.writeAll(data);
}

/// A writer interface backed by socket writes.
pub const StreamWriter = struct {
    stream: std_compat.net.Stream,

    pub fn write(self: StreamWriter, data: []const u8) !usize {
        return streamWrite(self.stream, data);
    }

    pub fn writeAll(self: StreamWriter, data: []const u8) !void {
        return streamWriteAll(self.stream, data);
    }
};

pub fn safeWriter(stream: std_compat.net.Stream) StreamWriter {
    return .{ .stream = stream };
}
