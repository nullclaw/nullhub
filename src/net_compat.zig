const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");

const windows_socket_error = -1;
const wsaeconnaborted = 10053;
const wsaeconnreset = 10054;
const wsaenetreset = 10052;
const wsaenotconn = 10057;
const wsaetimedout = 10060;

const ws2_32 = struct {
    extern "ws2_32" fn recv(
        socket: std.posix.socket_t,
        buf: ?*anyopaque,
        len: i32,
        flags: i32,
    ) callconv(std.builtin.CallingConvention.winapi) i32;

    extern "ws2_32" fn send(
        socket: std.posix.socket_t,
        buf: ?*const anyopaque,
        len: i32,
        flags: i32,
    ) callconv(std.builtin.CallingConvention.winapi) i32;

    extern "ws2_32" fn WSAGetLastError() callconv(std.builtin.CallingConvention.winapi) i32;
};

/// Windows-safe socket read. Zig 0.15.2's std.net.Stream.read() uses
/// NtReadFile/ReadFile on Windows, which fails on sockets with
/// GetLastError(87) "The parameter is incorrect".
///
/// This wrapper uses ws2_32.recv on Windows and falls back to the
/// standard stream.read() on other platforms.
pub fn streamRead(stream: std_compat.net.Stream, buffer: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        return windowsSocketRecv(stream.handle, buffer);
    }
    return stream.read(buffer);
}

/// Windows-safe socket write. Same issue as read — uses ws2_32.send
/// instead of WriteFile/NtWriteFile on Windows.
pub fn streamWrite(stream: std_compat.net.Stream, data: []const u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        return windowsSocketSend(stream.handle, data);
    }
    return stream.write(data);
}

/// Write all data to a Windows socket.
pub fn streamWriteAll(stream: std_compat.net.Stream, data: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        var offset: usize = 0;
        while (offset < data.len) {
            offset += try windowsSocketSend(stream.handle, data[offset..]);
        }
        return;
    }
    return stream.writeAll(data);
}

/// A writer interface backed by Windows-safe socket writes.
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

// ── Windows socket internals ────────────────────────────────────────

fn windowsSocketRecv(handle: std.os.windows.HANDLE, buffer: []u8) !usize {
    const rc = ws2_32.recv(handle, buffer.ptr, @intCast(buffer.len), 0);
    if (rc == windows_socket_error) {
        const err = ws2_32.WSAGetLastError();
        return switch (err) {
            wsaeconnreset, wsaeconnaborted, wsaenetreset => error.ConnectionResetByPeer,
            wsaetimedout => error.ConnectionTimedOut,
            wsaenotconn => error.SocketNotConnected,
            else => error.Unexpected,
        };
    }
    const bytes: usize = @intCast(rc);
    if (bytes == 0) return 0; // clean close
    return bytes;
}

fn windowsSocketSend(handle: std.os.windows.HANDLE, data: []const u8) !usize {
    const rc = ws2_32.send(handle, data.ptr, @intCast(data.len), 0);
    if (rc == windows_socket_error) {
        const err = ws2_32.WSAGetLastError();
        return switch (err) {
            wsaeconnreset, wsaeconnaborted, wsaenetreset => error.ConnectionResetByPeer,
            wsaetimedout => error.ConnectionTimedOut,
            wsaenotconn => error.SocketNotConnected,
            else => error.Unexpected,
        };
    }
    return @intCast(rc);
}
